//
//  BinViewModelTests.swift
//  WXYCDJTests
//
//  Pins BinViewModel's full lifecycle: refresh success (entries sorted
//  newest-first), refresh failure transitions to .error, remove success
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
    @Test func refreshLoadsEntriesSortedNewestFirst() async throws {
        let (client, session) = try await SignedInClient.make()
        let viewModel = BinViewModel(api: client)

        session.enqueue(StubRequestSession.Stub(
            statusCode: 200,
            body: Data(Fixtures.djBinResponseJSON.utf8)
        ))
        await viewModel.refresh()

        #expect(viewModel.state == .loaded)
        #expect(viewModel.entries.count == 2)
        // Fixture has Juana (added 2025-11-01) then Pratt (added 2025-11-02);
        // refresh() sorts by addedAt descending, so Pratt comes first.
        #expect(viewModel.entries[0].albumTitle == "On Your Own Love Again")
        #expect(viewModel.entries[1].albumTitle == "DOGA")
        #expect(viewModel.removeError == nil)
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

    @Test func removeSuccessDropsRowAndLeavesNoError() async throws {
        let (client, session) = try await SignedInClient.make()
        let viewModel = BinViewModel(api: client)

        session.enqueue(StubRequestSession.Stub(
            statusCode: 200,
            body: Data(Fixtures.djBinResponseJSON.utf8)
        ))
        await viewModel.refresh()
        let target = try #require(viewModel.entries.first)

        session.enqueue(StubRequestSession.Stub(statusCode: 200))
        await viewModel.remove(target)

        #expect(viewModel.entries.count == 1)
        #expect(!viewModel.entries.contains { $0.id == target.id })
        #expect(viewModel.removeError == nil)
        #expect(viewModel.state == .loaded)
    }

    @Test func removeFailurePreservesEntriesAndPopulatesRemoveError() async throws {
        let (client, session) = try await SignedInClient.make()
        let viewModel = BinViewModel(api: client)

        session.enqueue(StubRequestSession.Stub(
            statusCode: 200,
            body: Data(Fixtures.djBinResponseJSON.utf8)
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
        #expect(viewModel.entries.contains { $0.id == target.id })
        #expect(viewModel.state == .loaded)
    }

    // MARK: Issue #60 — offline snapshot

    @Test func refreshSuccessWritesTheSnapshot() async throws {
        let (client, session) = try await SignedInClient.make()
        let store = SpyBinStore()
        let viewModel = BinViewModel(api: client, binStore: store)

        session.enqueue(StubRequestSession.Stub(
            statusCode: 200,
            body: Data(Fixtures.djBinResponseJSON.utf8)
        ))
        await viewModel.refresh()

        #expect(viewModel.state == .loaded)
        #expect(store.saveCalls.count == 1)
        // The persisted snapshot carries both fixture rows.
        #expect(Set(store.saveCalls[0].map(\.id)) == [1, 2])
    }

    @Test func coldLaunchOfflineShowsSnapshotAndRefreshFailureKeepsIt() async throws {
        let (client, session) = try await SignedInClient.make()
        // Prime the store as if a previous online session had persisted the bin.
        let store = SpyBinStore(initial: Self.persistedEntries)
        let viewModel = BinViewModel(api: client, binStore: store)

        // Cold launch: load the snapshot first (no network), then refresh fails.
        await viewModel.loadSnapshot()
        #expect(viewModel.state == .loaded)
        #expect(viewModel.entries.count == 2)
        // Sorted newest-first: Pratt (2025-11-02) before Juana (2025-11-01).
        #expect(viewModel.entries[0].albumTitle == "On Your Own Love Again")

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

    /// Two WXYC-representative bin entries modelling a previously-persisted
    /// snapshot. Juana added 2025-11-01, Pratt 2025-11-02, so a newest-first sort
    /// puts Pratt first — mirroring the `djBinResponseJSON` fixture's ordering.
    /// Built via the (testable) memberwise init so the test needn't re-implement
    /// WXYCAPI's internal wire decoder.
    static let persistedEntries: [BinEntry] = [
        BinEntry(
            id: 1, djId: 42, albumId: 100,
            addedAt: Date(timeIntervalSince1970: 1_730_500_000),
            albumTitle: "DOGA", artistName: "Juana Molina",
            codeLetters: "MOL", codeNumber: 12
        ),
        BinEntry(
            id: 2, djId: 42, albumId: 200,
            addedAt: Date(timeIntervalSince1970: 1_730_600_000),
            albumTitle: "On Your Own Love Again", artistName: "Jessica Pratt",
            codeLetters: "PRA", codeNumber: 5
        ),
    ]
}
