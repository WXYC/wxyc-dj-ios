//
//  CatalogRefreshServiceTests.swift
//  WXYCAPITests
//
//  Decision-logic tests for the shared CatalogRefreshService (issue #19 step 4):
//  a 304 touches neither the store nor the index, a 200 wholesale-replaces the
//  store and diff-reindexes (dropping vanished ids), the poll watermark is
//  sourced from the index commit (so a failed reindex does NOT advance it and the
//  next poll re-attempts), and an end-to-end pass over the real store + indexer.
//
//  Created by Jake on 06/23/26.
//  Copyright © 2026 WXYC. All rights reserved.
//

import Foundation
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
        let service = CatalogRefreshService(client: client, store: store, indexer: indexer)
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

    // MARK: 200 — replace + diff-reindex

    @Test func modifiedReplacesStoreAndReindexesDroppingVanishedIDs() async throws {
        let (client, session) = try await Self.makeSignedInClient()
        // Previously cloned {100, 999}; the new export is {100, 200}, so 999 vanished.
        let store = SpyCatalogStore(rows: [Self.row(100), Self.row(999)])
        let indexer = SpyCatalogIndexer(watermark: nil)
        let service = CatalogRefreshService(client: client, store: store, indexer: indexer)
        session.enqueue(StubRequestSession.Stub(
            statusCode: 200,
            headers: ["Last-Modified": "Tue, 02 Jun 2026 09:30:00 GMT"],
            body: Data(Fixtures.catalogNDJSON.utf8)
        ))

        let outcome = try await service.refresh()

        #expect(outcome == .refreshed(rowCount: 2, removed: 1))
        #expect(store.replaceCalls == [
            .init(rowIDs: [100, 200], lastModified: "Tue, 02 Jun 2026 09:30:00 GMT")
        ])
        // observedStoreIDs == the NEW ids proves the store was replaced BEFORE the
        // reindex read it — a service that reindexed first would observe {100, 999}.
        #expect(indexer.reindexCalls == [
            .init(removedIDs: [999], watermark: "Tue, 02 Jun 2026 09:30:00 GMT", observedStoreIDs: [100, 200])
        ])
        #expect(indexer.indexedWatermark() == "Tue, 02 Jun 2026 09:30:00 GMT")
        // First-ever poll (nil index watermark) carries no conditional header.
        let request = try #require(Self.catalogRequests(session).last)
        #expect(request.value(forHTTPHeaderField: "If-Modified-Since") == nil)
    }

    @Test func firstPopulationFromEmptyStoreRemovesNothing() async throws {
        let (client, session) = try await Self.makeSignedInClient()
        let store = SpyCatalogStore()
        let indexer = SpyCatalogIndexer(watermark: nil)
        let service = CatalogRefreshService(client: client, store: store, indexer: indexer)
        session.enqueue(StubRequestSession.Stub(
            statusCode: 200,
            headers: ["Last-Modified": "W"],
            body: Data(Fixtures.catalogNDJSON.utf8)
        ))

        let outcome = try await service.refresh()

        #expect(outcome == .refreshed(rowCount: 2, removed: 0))
        #expect(indexer.reindexCalls == [
            .init(removedIDs: [], watermark: "W", observedStoreIDs: [100, 200])
        ])
    }

    // MARK: poll() — the cheap background app-refresh probe

    @Test func pollOn304ReturnsFalseAndTouchesNeitherStoreNorIndex() async throws {
        let (client, session) = try await Self.makeSignedInClient()
        let watermark = "Mon, 01 Jun 2026 12:00:00 GMT"
        let store = SpyCatalogStore(rows: try Fixtures.catalogRows(), watermark: watermark)
        let indexer = SpyCatalogIndexer(watermark: watermark)
        let service = CatalogRefreshService(client: client, store: store, indexer: indexer)
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
        let service = CatalogRefreshService(client: client, store: store, indexer: indexer)
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
        let service = CatalogRefreshService(client: client, store: store, indexer: indexer)

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

    // MARK: Data safety — empty export

    @Test func emptyExportIsSkippedAndDoesNotWipeTheClone() async throws {
        let (client, session) = try await Self.makeSignedInClient()
        let store = SpyCatalogStore(rows: try Fixtures.catalogRows(), watermark: "W")
        let indexer = SpyCatalogIndexer(watermark: "W")
        let service = CatalogRefreshService(client: client, store: store, indexer: indexer)
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

    // MARK: Crash safety — watermark gated on the index commit

    @Test func failedReindexDoesNotAdvanceWatermarkAndNextLaunchRetries() async throws {
        let (client, session) = try await Self.makeSignedInClient()
        // The store persists across launches (one SQLite file in production); model
        // that by handing the same store to both "launches".
        let store = SpyCatalogStore()

        // First launch: the reindex fails mid-commit.
        let indexer1 = SpyCatalogIndexer(watermark: "OLD", shouldFail: true)
        let service1 = CatalogRefreshService(client: client, store: store, indexer: indexer1)
        session.enqueue(StubRequestSession.Stub(
            statusCode: 200,
            headers: ["Last-Modified": "NEW"],
            body: Data(Fixtures.catalogNDJSON.utf8)
        ))

        await #expect(throws: SpyCatalogIndexer.ReindexFailure.self) {
            try await service1.refresh()
        }
        // The store was replaced (it is briefly ahead of the index)...
        #expect(store.replaceCalls.map(\.lastModified) == ["NEW"])
        // ...but the index commit failed, so its watermark did NOT advance...
        #expect(indexer1.indexedWatermark() == "OLD")
        // ...and the failed poll was conditional on the un-advanced "OLD".
        #expect(Self.catalogRequests(session).last?.value(forHTTPHeaderField: "If-Modified-Since") == "OLD")

        // Next launch: a FRESH index handle (a failed Core Spotlight batch can't be
        // retried in-process per CatalogIndexing's contract — recovery is a new
        // CSSearchableIndex or the next process launch) reads the still-"OLD"
        // committed client state and re-attempts.
        let indexer2 = SpyCatalogIndexer(watermark: "OLD", shouldFail: false)
        let service2 = CatalogRefreshService(client: client, store: store, indexer: indexer2)
        session.enqueue(StubRequestSession.Stub(
            statusCode: 200,
            headers: ["Last-Modified": "NEW"],
            body: Data(Fixtures.catalogNDJSON.utf8)
        ))

        let outcome = try await service2.refresh()

        #expect(outcome == .refreshed(rowCount: 2, removed: 0))
        #expect(indexer2.reindexCalls.count == 1)        // the retry actually reindexed
        #expect(indexer2.indexedWatermark() == "NEW")
        #expect(Self.catalogRequests(session).count == 2)
        // The retry polled conditionally against the un-advanced "OLD" watermark.
        #expect(Self.catalogRequests(session).last?.value(forHTTPHeaderField: "If-Modified-Since") == "OLD")
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
        let service = CatalogRefreshService(client: client, store: store, indexer: indexer)

        // First refresh: 200 populates the store and the index, committing "W".
        session.enqueue(StubRequestSession.Stub(
            statusCode: 200,
            headers: ["Last-Modified": "W"],
            body: Data(Fixtures.catalogNDJSON.utf8)
        ))
        let first = try await service.refresh()

        #expect(first == .refreshed(rowCount: 2, removed: 0))
        #expect(try await store.count() == 2)
        #expect(fake.recording.indexedItems.map(\.identifier) == ["album.100", "album.200"])
        #expect(fake.recording.committedClientState == Data("W".utf8))

        // Second refresh: the index watermark "W" goes out as If-Modified-Since
        // and the server answers 304 — a no-op.
        session.enqueue(StubRequestSession.Stub(statusCode: 304))
        let second = try await service.refresh()

        #expect(second == .upToDate)
        #expect(Self.catalogRequests(session).last?.value(forHTTPHeaderField: "If-Modified-Since") == "W")
        #expect(fake.recording.endCount == 1) // no second commit
    }
}
