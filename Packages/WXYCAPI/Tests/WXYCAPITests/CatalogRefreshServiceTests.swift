//
//  CatalogRefreshServiceTests.swift
//  WXYCAPITests
//
//  Decision-logic tests for the shared CatalogRefreshService (issue #19 step 4):
//  a 304 touches neither the store nor the index, a 200 wholesale-replaces the
//  store and hands the in-memory snapshot to the indexer (which derives the
//  add/change/remove delta against its own map, issue #36), the poll watermark is
//  sourced from the index commit (so a failed reindex does NOT advance it and the
//  next poll re-attempts), and an end-to-end pass over the real store + indexer.
//
//  Created by Jake on 06/23/26.
//  Copyright © 2026 WXYC. All rights reserved.
//

import Foundation
import os
import Testing
@testable import WXYCAPI

@Suite("CatalogRefreshService", .serialized)
@MainActor
struct CatalogRefreshServiceTests {
    private static let config = WXYCAPIConfiguration.localDevelopment

    /// Stand up an `APIClient` already signed in (a cached JWT), over a stub
    /// session the test scripts catalog responses into.
    private static func makeSignedInClient() async throws -> (APIClient, StubRequestSession) {
        let session = StubRequestSession()
        let storage = InMemoryTokenStorage()
        try storage.save("session-abc", for: .sessionToken)
        let auth = AuthService(configuration: config, storage: storage, session: session)
        session.enqueue(StubRequestSession.Stub(
            statusCode: 200,
            body: Data(#"{"token":"\#(Fixtures.jwt())"}"#.utf8)
        ))
        await auth.restoreSession()
        let client = APIClient(configuration: config, session: session, authService: auth)
        return (client, session)
    }

    /// A minimal stand-in catalog row with the given id.
    static func row(_ id: Int) -> CatalogRow {
        CatalogRow(
            id: id, artistName: "Artist \(id)", albumTitle: "Album \(id)",
            codeLetters: "AAA", codeNumber: id, codeArtistNumber: 1,
            label: nil, genreName: nil, formatName: nil,
            onStreaming: nil, plays: nil, artworkURL: nil,
            rotationBin: nil, rotationKillDate: nil
        )
    }

    /// The `/library/catalog` requests recorded by the session, in order.
    static func catalogRequests(_ session: StubRequestSession) -> [URLRequest] {
        session.recordedRequests.filter { ($0.url?.path.contains("catalog")) == true }
    }

    // MARK: 304 — nothing happens

    @Test func notModifiedTouchesNeitherStoreNorIndex() async throws {
        let (client, session) = try await Self.makeSignedInClient()
        let watermark = "Mon, 01 Jun 2026 12:00:00 GMT"
        let store = SpyCatalogStore(rows: try Fixtures.catalogRows(), watermark: watermark)
        let indexer = SpyCatalogIndexer(watermark: watermark)
        let service = CatalogRefreshService(client: client, store: store, makeIndexer: { indexer })
        session.enqueue(StubRequestSession.Stub(statusCode: 304))

        let outcome = try await service.refresh()

        #expect(outcome == .upToDate)
        #expect(store.replaceCalls.isEmpty)
        #expect(indexer.reindexCalls.isEmpty)
        #expect(indexer.indexedWatermark() == watermark)
        // Polled conditionally against the index watermark.
        let request = try #require(Self.catalogRequests(session).last)
        #expect(request.value(forHTTPHeaderField: "If-Modified-Since") == watermark)
    }

    // MARK: 200 — replace + hand the snapshot to the indexer

    @Test func modifiedReplacesStoreAndHandsSnapshotToIndexer() async throws {
        let (client, session) = try await Self.makeSignedInClient()
        // The INDEX previously held {100, 999} (the removed set now derives from the
        // indexer's own map, not the store); the new export is {100, 200}. Row 100
        // is byte-identical to its export row (unchanged), so the delta is: add 200,
        // remove 999. The store starts empty — its contents no longer drive the diff.
        let indexedRows = [try Fixtures.catalogRows()[0], Self.row(999)]
        let store = SpyCatalogStore()
        let indexer = SpyCatalogIndexer(watermark: nil, indexedRows: indexedRows)
        let service = CatalogRefreshService(client: client, store: store, makeIndexer: { indexer })
        session.enqueue(StubRequestSession.Stub(
            statusCode: 200,
            headers: ["Last-Modified": "Tue, 02 Jun 2026 09:30:00 GMT"],
            body: Data(Fixtures.catalogNDJSON.utf8)
        ))

        let outcome = try await service.refresh()

        // upserted 1 (id 200 added; id 100 unchanged) + removed 1 (id 999).
        #expect(outcome == .refreshed(rowCount: 2, upserted: 1, removed: 1))
        #expect(store.replaceCalls == [
            .init(rowIDs: [100, 200], lastModified: "Tue, 02 Jun 2026 09:30:00 GMT")
        ])
        // The service hands the indexer the full NEW export snapshot; the indexer
        // derives the remove set internally from its own map.
        #expect(indexer.reindexCalls == [
            .init(snapshotIDs: [100, 200], watermark: "Tue, 02 Jun 2026 09:30:00 GMT", upserted: 1, removed: 1)
        ])
        #expect(indexer.indexedWatermark() == "Tue, 02 Jun 2026 09:30:00 GMT")
        // First-ever poll (nil index watermark) carries no conditional header.
        let request = try #require(Self.catalogRequests(session).last)
        #expect(request.value(forHTTPHeaderField: "If-Modified-Since") == nil)
    }

    @Test func firstPopulationFromEmptyIndexRemovesNothing() async throws {
        let (client, session) = try await Self.makeSignedInClient()
        let store = SpyCatalogStore()
        let indexer = SpyCatalogIndexer(watermark: nil)   // empty map -> all adds
        let service = CatalogRefreshService(client: client, store: store, makeIndexer: { indexer })
        session.enqueue(StubRequestSession.Stub(
            statusCode: 200,
            headers: ["Last-Modified": "W"],
            body: Data(Fixtures.catalogNDJSON.utf8)
        ))

        let outcome = try await service.refresh()

        #expect(outcome == .refreshed(rowCount: 2, upserted: 2, removed: 0))
        #expect(indexer.reindexCalls == [
            .init(snapshotIDs: [100, 200], watermark: "W", upserted: 2, removed: 0)
        ])
    }

    // MARK: poll() — the cheap background app-refresh probe

    @Test func pollOn304ReturnsFalseAndTouchesNeitherStoreNorIndex() async throws {
        let (client, session) = try await Self.makeSignedInClient()
        let watermark = "Mon, 01 Jun 2026 12:00:00 GMT"
        let store = SpyCatalogStore(rows: try Fixtures.catalogRows(), watermark: watermark)
        let indexer = SpyCatalogIndexer(watermark: watermark)
        let service = CatalogRefreshService(client: client, store: store, makeIndexer: { indexer })
        session.enqueue(StubRequestSession.Stub(statusCode: 304))

        let changed = try await service.poll()

        #expect(changed == false)
        // A poll is read-only: it never replaces the store or reindexes (that is
        // the reindex leg's job, deferred to a charging-gated processing task).
        #expect(store.replaceCalls.isEmpty)
        #expect(indexer.reindexCalls.isEmpty)
        #expect(indexer.indexedWatermark() == watermark)   // not advanced
        // Polled conditionally against the index's committed watermark.
        let request = try #require(Self.catalogRequests(session).last)
        #expect(request.value(forHTTPHeaderField: "If-Modified-Since") == watermark)
    }

    @Test func pollOn200ReturnsTrueWithoutReplacingStoreOrReindexing() async throws {
        let (client, session) = try await Self.makeSignedInClient()
        let store = SpyCatalogStore(rows: [Self.row(100)], watermark: "OLD")
        let indexer = SpyCatalogIndexer(watermark: "OLD")
        let service = CatalogRefreshService(client: client, store: store, makeIndexer: { indexer })
        session.enqueue(StubRequestSession.Stub(
            statusCode: 200,
            headers: ["Last-Modified": "Tue, 02 Jun 2026 09:30:00 GMT"],
            body: Data(Fixtures.catalogNDJSON.utf8)
        ))

        let changed = try await service.poll()

        // A 200 means the catalog moved — the caller (the BGAppRefreshTask leg)
        // submits the reindex processing task — but the poll itself does no heavy
        // work: the store is untouched and the index watermark does not advance.
        #expect(changed == true)
        #expect(store.replaceCalls.isEmpty)
        #expect(indexer.reindexCalls.isEmpty)
        #expect(indexer.indexedWatermark() == "OLD")
        let request = try #require(Self.catalogRequests(session).last)
        #expect(request.value(forHTTPHeaderField: "If-Modified-Since") == "OLD")
    }

    // MARK: No session — the silent-skip boundary the background handlers rely on

    @Test func refreshAndPollWithNoSessionThrowNotSignedInAndTouchNothing() async throws {
        // A client with no stored session: currentJWT() throws
        // AuthError.notSignedIn, which APIClient maps to APIError.notSignedIn.
        // This is the boundary AppDependencies.refreshCatalog()/handleBackgroundPoll()
        // catch to skip silently (never a sign-in prompt) — issue #19 step 5.
        let session = StubRequestSession()
        let auth = AuthService(configuration: Self.config, storage: InMemoryTokenStorage(), session: session)
        await auth.restoreSession()   // no token -> .signedOut
        let client = APIClient(configuration: Self.config, session: session, authService: auth)
        let store = SpyCatalogStore(rows: try Fixtures.catalogRows(), watermark: "W")
        let indexer = SpyCatalogIndexer(watermark: "W")
        let service = CatalogRefreshService(client: client, store: store, makeIndexer: { indexer })

        do {
            _ = try await service.refresh()
            Issue.record("expected refresh() to throw without a session")
        } catch APIError.notSignedIn {
            // expected
        }
        do {
            _ = try await service.poll()
            Issue.record("expected poll() to throw without a session")
        } catch APIError.notSignedIn {
            // expected
        }

        // currentJWT() short-circuits before any network call, and the clone is
        // untouched — so the handlers' catch is a true no-op skip.
        #expect(Self.catalogRequests(session).isEmpty)
        #expect(store.replaceCalls.isEmpty)
        #expect(indexer.reindexCalls.isEmpty)
        #expect(indexer.indexedWatermark() == "W")
    }

    // MARK: Fresh indexer per run — crash/in-process-retry recovery

    @Test func failedReindexRecoversInProcessWithAFreshIndexer() async throws {
        // CatalogIndexing's contract: a reindex that throws mid-batch leaves a
        // dangling Core Spotlight batch recoverable only on a FRESH index instance.
        // The service builds a fresh indexer per run, so a SINGLE service recovers
        // on its NEXT refresh() in the SAME process — no relaunch. Model the
        // daemon's persisted client state (which a failed reindex leaves at "OLD")
        // by seeding each fresh spy at "OLD": run 1 fails its commit; run 2 gets a
        // fresh indexer that reads the un-advanced "OLD" and succeeds.
        let (client, session) = try await Self.makeSignedInClient()
        let store = SpyCatalogStore()   // one store, persists across runs (one SQLite file in prod)
        let built = OSAllocatedUnfairLock<[SpyCatalogIndexer]>(initialState: [])
        let service = CatalogRefreshService(client: client, store: store) {
            built.withLock { made in
                let indexer = SpyCatalogIndexer(watermark: "OLD", shouldFail: made.isEmpty)
                made.append(indexer)
                return indexer
            }
        }

        // Run 1 (fresh indexer #1) fails mid-commit.
        session.enqueue(StubRequestSession.Stub(
            statusCode: 200, headers: ["Last-Modified": "NEW"], body: Data(Fixtures.catalogNDJSON.utf8)
        ))
        await #expect(throws: SpyCatalogIndexer.ReindexFailure.self) {
            try await service.refresh()
        }

        // Run 2 — SAME service — gets a FRESH indexer (#2) and recovers in-process.
        session.enqueue(StubRequestSession.Stub(
            statusCode: 200, headers: ["Last-Modified": "NEW"], body: Data(Fixtures.catalogNDJSON.utf8)
        ))
        let outcome = try await service.refresh()

        let indexers = built.withLock { $0 }
        #expect(indexers.count == 2)                      // a fresh indexer per run, in-process
        #expect(indexers[0].indexedWatermark() == "OLD")  // #1 failed -> watermark NOT advanced
        #expect(indexers[1].indexedWatermark() == "NEW")  // #2 (fresh) recovered and committed
        #expect(indexers[1].reindexCalls.count == 1)      // the retry actually reindexed
        #expect(outcome == .refreshed(rowCount: 2, upserted: 2, removed: 0))
        // The store was replaced on each run (briefly ahead of the index)...
        #expect(store.replaceCalls.map(\.lastModified) == ["NEW", "NEW"])
        // ...and both polls were conditional on the un-advanced "OLD" watermark.
        #expect(Self.catalogRequests(session).count == 2)
        #expect(Self.catalogRequests(session).last?.value(forHTTPHeaderField: "If-Modified-Since") == "OLD")
    }

    // MARK: Data safety — empty export

    @Test func emptyExportIsSkippedAndDoesNotWipeTheClone() async throws {
        let (client, session) = try await Self.makeSignedInClient()
        let store = SpyCatalogStore(rows: try Fixtures.catalogRows(), watermark: "W")
        let indexer = SpyCatalogIndexer(watermark: "W")
        let service = CatalogRefreshService(client: client, store: store, makeIndexer: { indexer })
        // A 200 carrying an EMPTY body (a backend export hiccup, not a real empty
        // catalog) must not wipe the last-good clone.
        session.enqueue(StubRequestSession.Stub(
            statusCode: 200,
            headers: ["Last-Modified": "EMPTY"],
            body: Data()
        ))

        let outcome = try await service.refresh()

        #expect(outcome == .skippedEmptyExport)
        #expect(store.replaceCalls.isEmpty)            // clone untouched
        #expect(try await store.count() == 2)
        #expect(indexer.reindexCalls.isEmpty)          // no reindex
        #expect(indexer.indexedWatermark() == "W")     // watermark not advanced
    }

    // MARK: End-to-end over the real store + indexer

    @Test func endToEndPopulatesRealStoreAndIndexThen304IsCheap() async throws {
        let (client, session) = try await Self.makeSignedInClient()
        let url = FileManager.default.temporaryDirectory
            .appending(path: "refresh-e2e-\(UUID().uuidString).sqlite")
        defer {
            let base = url.path(percentEncoded: false)
            try? FileManager.default.removeItem(at: url)
            for suffix in ["-journal", "-wal", "-shm"] {
                try? FileManager.default.removeItem(at: URL(filePath: base + suffix))
            }
        }
        let store = try SQLiteCatalogStore(url: url)
        let fake = FakeSearchableIndex()
        let indexer = SpotlightCatalogIndexer(index: fake)
        let service = CatalogRefreshService(client: client, store: store, makeIndexer: { indexer })

        // First refresh: 200 populates the store and the index, committing "W".
        session.enqueue(StubRequestSession.Stub(
            statusCode: 200,
            headers: ["Last-Modified": "W"],
            body: Data(Fixtures.catalogNDJSON.utf8)
        ))
        let first = try await service.refresh()

        #expect(first == .refreshed(rowCount: 2, upserted: 2, removed: 0))
        #expect(try await store.count() == 2)
        #expect(fake.recording.indexedItems.map(\.identifier) == ["album.100", "album.200"])
        #expect(fake.committedIndexState?.watermark == "W")

        // Second refresh: the index watermark "W" goes out as If-Modified-Since
        // and the server answers 304 — a no-op.
        session.enqueue(StubRequestSession.Stub(statusCode: 304))
        let second = try await service.refresh()

        #expect(second == .upToDate)
        #expect(Self.catalogRequests(session).last?.value(forHTTPHeaderField: "If-Modified-Since") == "W")
        #expect(fake.recording.endCount == 1) // no second commit
    }

    // MARK: cacheThumbnail — lazy thumbnail attach (issue #44)

    /// Write `bytes` to a unique temp file and return its URL (the "cached cover").
    private static func writeFixture(_ bytes: Data) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appending(path: "thumb-\(UUID().uuidString).jpg")
        try bytes.write(to: url)
        return url
    }

    @Test func cacheThumbnailUpsertsTheClonedRowsItemWithTheCachedBytes() async throws {
        let (client, _) = try await Self.makeSignedInClient()
        let store = SpyCatalogStore(rows: [Self.row(100)], watermark: "W")
        let bytes = Data([0xFF, 0xD8, 0xFF, 0xE0, 0x01, 0x02])
        let fileURL = try Self.writeFixture(bytes)
        defer { try? FileManager.default.removeItem(at: fileURL) }
        let provider = FakeThumbnailProvider(urls: [100: fileURL])
        let indexer = SpyCatalogIndexer(watermark: "W", indexedRows: [Self.row(100)])
        let service = CatalogRefreshService(
            client: client, store: store, makeIndexer: { indexer }, thumbnailProvider: provider)

        await service.cacheThumbnail(forAlbumID: 100)

        // The row is resolved from the clone and upserted with the cached bytes.
        #expect(provider.resolvedIDs == [100])
        #expect(indexer.upsertCalls == [.init(rowID: 100, thumbnailData: bytes)])
        // A thumbnail attach is not a refresh: no reindex, no store mutation, and
        // the index watermark is untouched.
        #expect(indexer.reindexCalls.isEmpty)
        #expect(store.replaceCalls.isEmpty)
        #expect(indexer.indexedWatermark() == "W")
    }

    @Test func cacheThumbnailIsANoOpWhenTheRowIsNotInTheClone() async throws {
        let (client, _) = try await Self.makeSignedInClient()
        let store = SpyCatalogStore()                       // empty clone
        let provider = FakeThumbnailProvider(urls: [:])
        let indexer = SpyCatalogIndexer(watermark: "W")
        let service = CatalogRefreshService(
            client: client, store: store, makeIndexer: { indexer }, thumbnailProvider: provider)

        await service.cacheThumbnail(forAlbumID: 404)

        // No clone row -> nothing to resolve or upsert.
        #expect(provider.resolvedIDs.isEmpty)
        #expect(indexer.upsertCalls.isEmpty)
    }

    @Test func cacheThumbnailIsANoOpWhenTheCoverIsUnfetchable() async throws {
        let (client, _) = try await Self.makeSignedInClient()
        let store = SpyCatalogStore(rows: [Self.row(100)], watermark: "W")
        let provider = FakeThumbnailProvider(urls: [:])     // resolves to nil (miss)
        let indexer = SpyCatalogIndexer(watermark: "W", indexedRows: [Self.row(100)])
        let service = CatalogRefreshService(
            client: client, store: store, makeIndexer: { indexer }, thumbnailProvider: provider)

        await service.cacheThumbnail(forAlbumID: 100)

        // The row was resolved, but with no cover bytes there is nothing to upsert.
        #expect(provider.resolvedIDs == [100])
        #expect(indexer.upsertCalls.isEmpty)
    }

    @Test func cacheThumbnailWithNoProviderIsANoOp() async throws {
        let (client, _) = try await Self.makeSignedInClient()
        let store = SpyCatalogStore(rows: [Self.row(100)], watermark: "W")
        let indexer = SpyCatalogIndexer(watermark: "W", indexedRows: [Self.row(100)])
        // No thumbnailProvider (the default) -> the catalog has no artwork feature.
        let service = CatalogRefreshService(client: client, store: store, makeIndexer: { indexer })

        await service.cacheThumbnail(forAlbumID: 100)

        #expect(indexer.upsertCalls.isEmpty)
    }

    @Test func cacheThumbnailEndToEndLeavesTheIndexWatermarkUnchanged() async throws {
        // Acceptance criterion: the single-item upsert never advances/clears the
        // watermark. End-to-end over the REAL indexer + a fake index seeded with
        // client state, so the watermark read goes through the actual codec.
        let (client, _) = try await Self.makeSignedInClient()
        let row = Self.row(100)
        let store = SpyCatalogStore(rows: [row], watermark: "WM")
        let seed = CatalogIndexState(
            watermark: "WM", fingerprints: [100: CatalogSpotlight.fingerprint(for: row)]
        ).encode()
        let fake = FakeSearchableIndex(initialClientState: seed)
        let bytes = ThumbnailDownscalingTests.makeJPEG(width: 64, height: 64)
        let fileURL = try Self.writeFixture(bytes)
        defer { try? FileManager.default.removeItem(at: fileURL) }
        let provider = FakeThumbnailProvider(urls: [100: fileURL])
        let service = CatalogRefreshService(
            client: client, store: store,
            makeIndexer: { SpotlightCatalogIndexer(index: fake) },
            thumbnailProvider: provider)

        await service.cacheThumbnail(forAlbumID: 100)

        // The item was upserted with the cover, as a plain non-batch write...
        #expect(fake.recording.indexedItems.map(\.identifier) == ["album.100"])
        #expect(fake.recording.indexedItems.first?.thumbnailData == bytes)
        #expect(fake.recording.beginCount == 0 && fake.recording.endCount == 0)
        // ...so the committed client state (watermark) is exactly what was seeded.
        #expect(fake.committedIndexState?.watermark == "WM")
    }

    // MARK: Serialization — both directions (issue #44)

    @Test func upsertDoesNotInterleaveWithAnInFlightReindexBatch() async throws {
        let (client, session) = try await Self.makeSignedInClient()
        let store = SpyCatalogStore(rows: [Self.row(100)], watermark: nil)
        let bytes = ThumbnailDownscalingTests.makeJPEG(width: 64, height: 64)
        let fileURL = try Self.writeFixture(bytes)
        defer { try? FileManager.default.removeItem(at: fileURL) }
        let provider = FakeThumbnailProvider(urls: [100: fileURL])

        let log = SpotlightEventLog()
        let gate = Gate()
        let calls = OSAllocatedUnfairLock(initialState: 0)
        let service = CatalogRefreshService(
            client: client, store: store,
            makeIndexer: {
                let n = calls.withLock { $0 += 1; return $0 }
                // The refresh (1st indexer) pauses at endBatch; later ones run free.
                let gated = GatedSearchableIndex(log: log, gateOp: n == 1 ? .end : nil, gate: n == 1 ? gate : nil)
                return SpotlightCatalogIndexer(index: gated)
            },
            thumbnailProvider: provider)
        session.enqueue(StubRequestSession.Stub(
            statusCode: 200, headers: ["Last-Modified": "W"], body: Data(Fixtures.catalogNDJSON.utf8)))

        // Start the refresh; wait until it is paused mid-batch (begin + index done,
        // end pending).
        let refreshTask = Task { try await service.refresh() }
        await gate.waitUntilReached()

        // Fire the upsert WHILE the refresh holds its batch open. If serialization
        // were broken it would slip its index write between begin and end.
        let upsertTask = Task { await service.cacheThumbnail(forAlbumID: 100) }
        try? await Task.sleep(for: .milliseconds(30))   // window for a broken impl to interleave
        gate.proceed()
        _ = try await refreshTask.value
        await upsertTask.value

        // The upsert's index write lands strictly AFTER the reindex batch closed.
        #expect(log.events == [
            .begin, .index(["album.100", "album.200"]), .end, .index(["album.100"]),
        ])
    }

    @Test func reindexDoesNotInterleaveWithAnInFlightUpsert() async throws {
        let (client, session) = try await Self.makeSignedInClient()
        let store = SpyCatalogStore(rows: [Self.row(100)], watermark: nil)
        let bytes = ThumbnailDownscalingTests.makeJPEG(width: 64, height: 64)
        let fileURL = try Self.writeFixture(bytes)
        defer { try? FileManager.default.removeItem(at: fileURL) }
        let provider = FakeThumbnailProvider(urls: [100: fileURL])

        let log = SpotlightEventLog()
        let gate = Gate()
        let calls = OSAllocatedUnfairLock(initialState: 0)
        let service = CatalogRefreshService(
            client: client, store: store,
            makeIndexer: {
                let n = calls.withLock { $0 += 1; return $0 }
                // The upsert (1st indexer) pauses at its index write; the refresh runs free.
                let gated = GatedSearchableIndex(log: log, gateOp: n == 1 ? .index : nil, gate: n == 1 ? gate : nil)
                return SpotlightCatalogIndexer(index: gated)
            },
            thumbnailProvider: provider)
        session.enqueue(StubRequestSession.Stub(
            statusCode: 200, headers: ["Last-Modified": "W"], body: Data(Fixtures.catalogNDJSON.utf8)))

        // Start the upsert; wait until it is paused at its (about-to-record) index write.
        let upsertTask = Task { await service.cacheThumbnail(forAlbumID: 100) }
        await gate.waitUntilReached()

        // Fire the refresh WHILE the upsert is mid-write. If serialization were
        // broken its reindex would open a batch during the upsert's write.
        let refreshTask = Task { try await service.refresh() }
        try? await Task.sleep(for: .milliseconds(30))
        gate.proceed()
        await upsertTask.value
        _ = try await refreshTask.value

        // The upsert's write completes before the reindex batch opens.
        #expect(log.events == [
            .index(["album.100"]), .begin, .index(["album.100", "album.200"]), .end,
        ])
    }

    @Test func overlappingRefreshesRunSequentiallyWithoutCoalescing() async throws {
        // Issue #44 traded refresh<->refresh coalescing for one serial chain: two
        // overlapping refreshes now run in sequence (the second a cheap 304), not
        // collapsed onto a single round-trip returning .refreshed to both.
        let (client, session) = try await Self.makeSignedInClient()
        let store = SpyCatalogStore()
        let indexer = SpyCatalogIndexer(watermark: nil)
        let service = CatalogRefreshService(client: client, store: store, makeIndexer: { indexer })
        session.enqueue(StubRequestSession.Stub(
            statusCode: 200, headers: ["Last-Modified": "W"], body: Data(Fixtures.catalogNDJSON.utf8)))
        session.enqueue(StubRequestSession.Stub(statusCode: 304))

        async let a = service.refresh()
        async let b = service.refresh()
        let outcomes = try await [a, b]

        // One did the 200; the other re-polled (watermark advanced) and got a 304.
        #expect(outcomes.contains(.refreshed(rowCount: 2, upserted: 2, removed: 0)))
        #expect(outcomes.contains(.upToDate))
        // Two round-trips — coalescing would have made exactly one.
        #expect(Self.catalogRequests(session).count == 2)
    }

    // MARK: poll() defers to a refresh, not a thumbnail upsert (issue #44)

    @Test func pollProceedsWhileAThumbnailUpsertIsInFlight() async throws {
        // A thumbnail upsert does NOT reindex, so it must not suppress the poll —
        // else a genuine catalog change would be missed for that cycle.
        let (client, session) = try await Self.makeSignedInClient()
        let store = SpyCatalogStore(rows: [Self.row(100)], watermark: nil)
        let fileURL = try Self.writeFixture(Data([0x01]))
        defer { try? FileManager.default.removeItem(at: fileURL) }
        let provider = FakeThumbnailProvider(urls: [100: fileURL])
        let log = SpotlightEventLog()
        let gate = Gate()
        let calls = OSAllocatedUnfairLock(initialState: 0)
        let service = CatalogRefreshService(
            client: client, store: store,
            makeIndexer: {
                let n = calls.withLock { $0 += 1; return $0 }
                // The upsert (1st indexer) pauses at its write; poll's own indexer runs free.
                let gated = GatedSearchableIndex(log: log, gateOp: n == 1 ? .index : nil, gate: n == 1 ? gate : nil)
                return SpotlightCatalogIndexer(index: gated)
            },
            thumbnailProvider: provider)

        let upsertTask = Task { await service.cacheThumbnail(forAlbumID: 100) }
        await gate.waitUntilReached()   // upsert is in flight (activeCount>0, refreshInFlight==0)

        session.enqueue(StubRequestSession.Stub(
            statusCode: 200, headers: ["Last-Modified": "W"], body: Data(Fixtures.catalogNDJSON.utf8)))
        let changed = try await service.poll()

        #expect(changed == true)                            // poll did its conditional GET
        #expect(Self.catalogRequests(session).count == 1)   // not short-circuited

        gate.proceed()
        await upsertTask.value
    }

    @Test func pollDefersToAnInFlightRefresh() async throws {
        // A refresh DOES reindex (and opens a batch), so the poll still defers to it.
        let (client, session) = try await Self.makeSignedInClient()
        let store = SpyCatalogStore(rows: [Self.row(100)], watermark: nil)
        let log = SpotlightEventLog()
        let gate = Gate()
        let calls = OSAllocatedUnfairLock(initialState: 0)
        let service = CatalogRefreshService(
            client: client, store: store,
            makeIndexer: {
                let n = calls.withLock { $0 += 1; return $0 }
                let gated = GatedSearchableIndex(log: log, gateOp: n == 1 ? .end : nil, gate: n == 1 ? gate : nil)
                return SpotlightCatalogIndexer(index: gated)
            })
        session.enqueue(StubRequestSession.Stub(
            statusCode: 200, headers: ["Last-Modified": "W"], body: Data(Fixtures.catalogNDJSON.utf8)))

        let refreshTask = Task { try await service.refresh() }
        await gate.waitUntilReached()   // refresh is mid-reindex (refreshInFlight>0)

        let changed = try await service.poll()

        #expect(changed == false)                           // deferred to the refresh
        #expect(Self.catalogRequests(session).count == 1)   // poll issued no GET of its own

        gate.proceed()
        _ = try await refreshTask.value
    }

    // MARK: Thumbnail dedup keyed on the cover file (issue #44)

    @Test func cacheThumbnailSkipsARedundantReattachOfTheSameCover() async throws {
        let (client, _) = try await Self.makeSignedInClient()
        let store = SpyCatalogStore(rows: [Self.row(100)], watermark: "W")
        let fileURL = try Self.writeFixture(Data([0x01, 0x02]))
        defer { try? FileManager.default.removeItem(at: fileURL) }
        let provider = FakeThumbnailProvider(urls: [100: fileURL])
        let indexer = SpyCatalogIndexer(watermark: "W", indexedRows: [Self.row(100)])
        let service = CatalogRefreshService(
            client: client, store: store, makeIndexer: { indexer }, thumbnailProvider: provider)

        await service.cacheThumbnail(forAlbumID: 100)
        await service.cacheThumbnail(forAlbumID: 100)   // same cover file -> deduped

        #expect(provider.resolvedIDs == [100, 100])     // resolved both times (cheap cache hit)
        #expect(indexer.upsertCalls.count == 1)         // but upserted only once
    }

    @Test func concurrentCacheThumbnailsForTheSameCoverUpsertOnce() async throws {
        // The dedup re-check + upsert + record are one serialized unit, so two
        // concurrent views of the same album collapse to a single upsert — a naive
        // check-outside / insert-outside would let both through.
        let (client, _) = try await Self.makeSignedInClient()
        let store = SpyCatalogStore(rows: [Self.row(100)], watermark: "W")
        let fileURL = try Self.writeFixture(Data([0x01, 0x02]))
        defer { try? FileManager.default.removeItem(at: fileURL) }
        let provider = FakeThumbnailProvider(urls: [100: fileURL])
        let indexer = SpyCatalogIndexer(watermark: "W", indexedRows: [Self.row(100)])
        let service = CatalogRefreshService(
            client: client, store: store, makeIndexer: { indexer }, thumbnailProvider: provider)

        async let a: Void = service.cacheThumbnail(forAlbumID: 100)
        async let b: Void = service.cacheThumbnail(forAlbumID: 100)
        _ = await (a, b)

        #expect(indexer.upsertCalls.count == 1)
    }

    @Test func reindexClearsTheThumbnailDedupSoAStrippedCoverReattaches() async throws {
        // A reindex re-upserts changed rows WITHOUT a thumbnail (the cached-only
        // attach is deferred), stripping their cover. The dedup must be cleared so
        // the next in-app view re-attaches it — an id/file-keyed skip that survived
        // the reindex would leave the cover blank until relaunch.
        let (client, session) = try await Self.makeSignedInClient()
        let store = SpyCatalogStore(rows: [Self.row(100)], watermark: nil)
        let fileURL = try Self.writeFixture(Data([0x01, 0x02]))
        defer { try? FileManager.default.removeItem(at: fileURL) }
        let provider = FakeThumbnailProvider(urls: [100: fileURL])
        let indexer = SpyCatalogIndexer(watermark: nil)   // empty map -> refresh upserts rows
        let service = CatalogRefreshService(
            client: client, store: store, makeIndexer: { indexer }, thumbnailProvider: provider)

        await service.cacheThumbnail(forAlbumID: 100)     // attach (upsert 1)
        session.enqueue(StubRequestSession.Stub(
            statusCode: 200, headers: ["Last-Modified": "W"], body: Data(Fixtures.catalogNDJSON.utf8)))
        _ = try await service.refresh()                   // reindex upserts -> clears the dedup
        await service.cacheThumbnail(forAlbumID: 100)     // re-attach (upsert 2)

        #expect(indexer.upsertCalls.count == 2)
    }
}
