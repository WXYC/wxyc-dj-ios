//
//  BinViewModelTests.swift
//  WXYCDJTests
//
//  Pins BinViewModel's full lifecycle: refresh success (entries sorted into
//  shelf order), refresh failure transitions to .error, remove success
//  drops the row, and remove failure populates `removeError` without
//  blowing the loaded list away (the surface added in PR #4). Plus the issue-#60
//  offline-snapshot surface: a successful refresh writes the snapshot, a cold
//  launch loads the snapshot first so an offline refresh keeps showing it, and a
//  never-loaded offline bin lands in .error without crashing.
//
//  Created by Jake on 5/19/26.
//  Copyright © 2026 WXYC. All rights reserved.
//

import Foundation
import Testing
@testable import WXYCAPI
@testable import WXYCDJ

@Suite("BinViewModel", .serialized)
@MainActor
struct BinViewModelTests {
    @Test func refreshLoadsEntriesInShelfOrder() async throws {
        let (client, session) = try await SignedInClient.make()
        let viewModel = BinViewModel(api: client)

        session.enqueue(StubRequestSession.Stub(
            statusCode: 200,
            body: Data(Fixtures.binResponseJSON.utf8)
        ))
        await viewModel.refresh()

        #expect(viewModel.state == .loaded)
        #expect(viewModel.entries.count == 2)
        // The wire hands back Pratt then Molina; refresh() re-sorts by filing
        // name, so "Molina, Juana" precedes "Pratt, Jessica".
        #expect(viewModel.entries[0].albumTitle == "DOGA")
        #expect(viewModel.entries[1].albumTitle == "On Your Own Love Again")
        #expect(viewModel.removeError == nil)
    }

    /// The bin is keyed by album: `GET /djs/bin` projects no `track_title`, so
    /// an album binned twice under different tracks comes back as two identical
    /// rows — and `DELETE /djs/bin` clears both at once. One row on screen.
    @Test func refreshCollapsesDuplicateAlbumRows() async throws {
        let (client, session) = try await SignedInClient.make()
        let store = SpyBinStore()
        let viewModel = BinViewModel(api: client, binStore: store)

        let duplicated = """
            [
              {"album_id": 100, "album_title": "DOGA", "artist_name": "Juana Molina",
               "alphabetical_name": "Molina, Juana", "code_letters": "MOL",
               "code_artist_number": 1, "code_number": 12},
              {"album_id": 100, "album_title": "DOGA", "artist_name": "Juana Molina",
               "alphabetical_name": "Molina, Juana", "code_letters": "MOL",
               "code_artist_number": 1, "code_number": 12}
            ]
            """
        session.enqueue(StubRequestSession.Stub(statusCode: 200, body: Data(duplicated.utf8)))
        await viewModel.refresh()

        #expect(viewModel.entries.count == 1)
        // The album-id-keyed store would reject a duplicate outright, so the
        // deduped list is what gets persisted.
        #expect(store.saveCalls == [viewModel.entries])
    }

    @Test func refreshFailureTransitionsToError() async throws {
        let (client, session) = try await SignedInClient.make()
        let viewModel = BinViewModel(api: client)

        session.enqueue(StubRequestSession.Stub(statusCode: 500, body: Data(#"{"error":"boom"}"#.utf8)))
        await viewModel.refresh()

        if case .error = viewModel.state {
            // pass
        } else {
            Issue.record("expected .error state, got \(viewModel.state)")
        }
        #expect(viewModel.entries.isEmpty)
    }

    /// Issue #106: the load-failure arm reports. `GET /djs/bin` failing is a
    /// silent field defect otherwise — the DJ just sees "Couldn't load bin".
    @Test func refreshFailureReportsToErrorReporter() async throws {
        let (client, session) = try await SignedInClient.make()
        let spy = SpyErrorReporter()
        let viewModel = BinViewModel(api: client, errorReporter: spy)

        session.enqueue(StubRequestSession.Stub(statusCode: 500, body: Data(#"{"error":"boom"}"#.utf8)))
        await viewModel.refresh()

        #expect(spy.reportCount == 1)
        #expect(spy.reports.first?.context == "BinViewModel.refresh")
    }

    /// Issue #106 review Fix 1: being offline is a supported mode, never a
    /// defect — the bin already falls back to its offline snapshot (issue
    /// #60) exactly as designed, so an offline refresh must not generate a
    /// Sentry event.
    @Test func refreshOfflineFailureDoesNotReportToErrorReporter() async throws {
        let (client, session) = try await SignedInClient.make()
        let spy = SpyErrorReporter()
        let viewModel = BinViewModel(api: client, errorReporter: spy)

        session.enqueue(failure: URLError(.notConnectedToInternet))
        await viewModel.refresh()

        #expect(spy.reportCount == 0)
    }

    @Test func removeSuccessDropsRowAndLeavesNoError() async throws {
        let (viewModel, _, target) = try await Self.removeFirstAfterRefresh()

        #expect(viewModel.entries.count == 1)
        #expect(!viewModel.entries.contains { $0.albumId == target.albumId })
        #expect(viewModel.removeError == nil)
        #expect(viewModel.state == .loaded)
    }

    /// A remove has to reach the persisted snapshot too, or the next cold launch
    /// resurrects the release from the store before the network refresh lands.
    @Test func removeSuccessPersistsTheShrunkenSnapshot() async throws {
        let (_, store, target) = try await Self.removeFirstAfterRefresh()

        // Two saves: the refresh, then the remove.
        #expect(store.saveCalls.count == 2)
        #expect(!store.saveCalls[1].contains { $0.albumId == target.albumId })
        #expect(store.saveCalls[1].count == 1)
    }

    /// The snapshot write is best-effort: a failing store must not turn a
    /// successful remove into an error the DJ has to dismiss.
    @Test func removeSurvivesAFailingSnapshotWrite() async throws {
        let (viewModel, _, _) = try await Self.removeFirstAfterRefresh(throwOnSave: true)

        #expect(viewModel.removeError == nil)
        #expect(viewModel.entries.count == 1)
        #expect(viewModel.state == .loaded)
    }

    /// Issue #106: the snapshot-save-failure arm reports, even though it's
    /// best-effort on screen (no `removeError`, no `.error` state) — a
    /// silently-stale offline bin is otherwise invisible.
    @Test func refreshSnapshotSaveFailureReportsToErrorReporter() async throws {
        let (client, session) = try await SignedInClient.make()
        let spy = SpyErrorReporter()
        let store = SpyBinStore(throwOnSave: true)
        let viewModel = BinViewModel(api: client, binStore: store, errorReporter: spy)

        session.enqueue(StubRequestSession.Stub(
            statusCode: 200,
            body: Data(Fixtures.binResponseJSON.utf8)
        ))
        await viewModel.refresh()

        #expect(viewModel.state == .loaded)  // the network refresh itself succeeded
        #expect(spy.reportCount == 1)
        #expect(spy.reports.first?.context == "BinViewModel.persistSnapshot")
    }

    // MARK: - Issue #108: bin analytics

    @Test func removeSuccessRecordsBinItemRemoved() async throws {
        let (client, session) = try await SignedInClient.make()
        let analytics = SpyAnalytics()
        let viewModel = BinViewModel(api: client, analytics: analytics)

        session.enqueue(StubRequestSession.Stub(
            statusCode: 200,
            body: Data(Fixtures.binResponseJSON.utf8)
        ))
        await viewModel.refresh()
        let target = try #require(viewModel.entries.first)

        session.enqueue(StubRequestSession.Stub(statusCode: 200))
        await viewModel.remove(target)

        #expect(analytics.captures.count == 1)
        let capture = try #require(analytics.captures.first)
        #expect(capture.name == "bin_item_removed")
        #expect(capture.properties["album_id"] == .int(target.albumId))
    }

    @Test func removeFailureRecordsNoAnalyticsEvent() async throws {
        let (client, session) = try await SignedInClient.make()
        let analytics = SpyAnalytics()
        let viewModel = BinViewModel(api: client, analytics: analytics)

        session.enqueue(StubRequestSession.Stub(
            statusCode: 200,
            body: Data(Fixtures.binResponseJSON.utf8)
        ))
        await viewModel.refresh()
        let target = try #require(viewModel.entries.first)

        session.enqueue(StubRequestSession.Stub(statusCode: 500, body: Data(#"{"error":"boom"}"#.utf8)))
        await viewModel.remove(target)

        #expect(analytics.captures.isEmpty)
    }

    @Test func removeFailurePreservesEntriesAndPopulatesRemoveError() async throws {
        let (client, session) = try await SignedInClient.make()
        let viewModel = BinViewModel(api: client)

        session.enqueue(StubRequestSession.Stub(
            statusCode: 200,
            body: Data(Fixtures.binResponseJSON.utf8)
        ))
        await viewModel.refresh()
        #expect(viewModel.state == .loaded)
        #expect(viewModel.entries.count == 2)
        #expect(viewModel.removeError == nil)

        let target = try #require(viewModel.entries.first)
        session.enqueue(StubRequestSession.Stub(statusCode: 500, body: Data(#"{"error":"boom"}"#.utf8)))
        await viewModel.remove(target)

        #expect(viewModel.removeError != nil)
        #expect(viewModel.entries.count == 2)
        #expect(viewModel.entries.contains { $0.albumId == target.albumId })
        #expect(viewModel.state == .loaded)
    }

    // MARK: Issue #60 — offline snapshot

    @Test func refreshSuccessWritesTheSnapshot() async throws {
        let (client, session) = try await SignedInClient.make()
        let store = SpyBinStore()
        let viewModel = BinViewModel(api: client, binStore: store)

        session.enqueue(StubRequestSession.Stub(
            statusCode: 200,
            body: Data(Fixtures.binResponseJSON.utf8)
        ))
        await viewModel.refresh()

        #expect(viewModel.state == .loaded)
        #expect(store.saveCalls.count == 1)
        // The persisted snapshot carries both fixture rows, keyed by album id.
        #expect(Set(store.saveCalls[0].map(\.albumId)) == [100, 200])
    }

    @Test func coldLaunchOfflineShowsSnapshotAndRefreshFailureKeepsIt() async throws {
        let (client, session) = try await SignedInClient.make()
        // Prime the store as if a previous online session had persisted the bin.
        let store = SpyBinStore(initial: try Self.persistedEntries())
        let viewModel = BinViewModel(api: client, binStore: store)

        // Cold launch: load the snapshot first (no network), then refresh fails.
        await viewModel.loadSnapshot()
        #expect(viewModel.state == .loaded)
        #expect(viewModel.entries.count == 2)
        // Shelf order applies to the persisted snapshot too: Molina before Pratt.
        #expect(viewModel.entries[0].albumTitle == "DOGA")

        session.enqueue(StubRequestSession.Stub(statusCode: 500, body: Data(#"{"error":"boom"}"#.utf8)))
        await viewModel.refresh()

        // The offline read survives the failed network call.
        #expect(viewModel.state == .loaded)
        #expect(viewModel.entries.count == 2)
    }

    @Test func neverLoadedOfflineLandsInErrorWithoutCrashing() async throws {
        let (client, session) = try await SignedInClient.make()
        let store = SpyBinStore() // never written -> snapshot() == nil
        let viewModel = BinViewModel(api: client, binStore: store)

        await viewModel.loadSnapshot()
        #expect(viewModel.entries.isEmpty)

        session.enqueue(StubRequestSession.Stub(statusCode: 500, body: Data(#"{"error":"boom"}"#.utf8)))
        await viewModel.refresh()

        if case .error = viewModel.state {
            // pass
        } else {
            Issue.record("expected .error state, got \(viewModel.state)")
        }
        #expect(viewModel.entries.isEmpty)
    }

    @Test func loadSnapshotIgnoresAStoreReadError() async throws {
        let (client, _) = try await SignedInClient.make()
        let store = SpyBinStore(throwOnSnapshot: true)
        let viewModel = BinViewModel(api: client, binStore: store)

        // A throwing snapshot read is best-effort: no crash, no entries, the
        // initial .loading state is left for refresh() to resolve.
        await viewModel.loadSnapshot()
        #expect(viewModel.entries.isEmpty)
        #expect(viewModel.state == .loading)
    }

    @Test func coldLaunchEmptyPersistedOfflineShowsEmptyNotError() async throws {
        let (client, session) = try await SignedInClient.make()
        // A previously-persisted *empty* bin. The store's snapshot-present marker
        // makes this `[]` (authoritative emptiness), distinct from a never-written
        // `nil` (modelled by SpyBinStore(initial: []) vs SpyBinStore()).
        let store = SpyBinStore(initial: [])
        let viewModel = BinViewModel(api: client, binStore: store)

        // Cold launch loads the empty-but-present snapshot: authoritative
        // emptiness, so `.loaded` (BinView renders the "Bin is empty" tray) — not
        // `.loading`, and definitely not `.error`.
        await viewModel.loadSnapshot()
        #expect(viewModel.state == .loaded)
        #expect(viewModel.entries.isEmpty)

        // Offline, the refresh fails: a known-empty bin keeps showing the empty
        // state instead of regressing to "Couldn't load bin".
        session.enqueue(StubRequestSession.Stub(statusCode: 500, body: Data(#"{"error":"boom"}"#.utf8)))
        await viewModel.refresh()
        #expect(viewModel.state == .loaded)
        #expect(viewModel.entries.isEmpty)
    }

    /// A previously-persisted snapshot, in the arbitrary order the server handed
    /// the rows over — decoded from the same wire fixture the network tests use,
    /// so the shelf sort (not the fixture's order) is what puts Molina first.
    static func persistedEntries() throws -> [BinEntry] {
        try Fixtures.binEntries()
    }

    /// Refresh from the two-row fixture, then remove the first entry. Shared by
    /// the three remove tests, which differ only in what they assert and whether
    /// the store's write fails.
    private static func removeFirstAfterRefresh(
        throwOnSave: Bool = false
    ) async throws -> (viewModel: BinViewModel, store: SpyBinStore, removed: BinEntry) {
        let (client, session) = try await SignedInClient.make()
        let store = SpyBinStore(throwOnSave: throwOnSave)
        let viewModel = BinViewModel(api: client, binStore: store)

        session.enqueue(StubRequestSession.Stub(
            statusCode: 200,
            body: Data(Fixtures.binResponseJSON.utf8)
        ))
        await viewModel.refresh()
        let target = try #require(viewModel.entries.first)

        session.enqueue(StubRequestSession.Stub(statusCode: 200))
        await viewModel.remove(target)
        return (viewModel, store, target)
    }
}
