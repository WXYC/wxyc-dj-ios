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

    @Test func removeSuccessDropsRowAndLeavesNoError() async throws {
        let (client, session) = try await SignedInClient.make()
        let viewModel = BinViewModel(api: client)

        session.enqueue(StubRequestSession.Stub(
            statusCode: 200,
            body: Data(Fixtures.binResponseJSON.utf8)
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

    /// A remove has to reach the persisted snapshot too, or the next cold launch
    /// resurrects the release from the store before the network refresh lands.
    @Test func removeSuccessPersistsTheShrunkenSnapshot() async throws {
        let (client, session) = try await SignedInClient.make()
        let store = SpyBinStore()
        let viewModel = BinViewModel(api: client, binStore: store)

        session.enqueue(StubRequestSession.Stub(
            statusCode: 200,
            body: Data(Fixtures.binResponseJSON.utf8)
        ))
        await viewModel.refresh()
        let target = try #require(viewModel.entries.first)

        session.enqueue(StubRequestSession.Stub(statusCode: 200))
        await viewModel.remove(target)

        // Two saves: the refresh, then the remove.
        #expect(store.saveCalls.count == 2)
        #expect(!store.saveCalls[1].contains { $0.id == target.id })
        #expect(store.saveCalls[1].count == 1)
    }

    /// The snapshot write is best-effort: a failing store must not turn a
    /// successful remove into an error the DJ has to dismiss.
    @Test func removeSurvivesAFailingSnapshotWrite() async throws {
        let (client, session) = try await SignedInClient.make()
        let store = SpyBinStore(throwOnSave: true)
        let viewModel = BinViewModel(api: client, binStore: store)

        session.enqueue(StubRequestSession.Stub(
            statusCode: 200,
            body: Data(Fixtures.binResponseJSON.utf8)
        ))
        await viewModel.refresh()
        let target = try #require(viewModel.entries.first)

        session.enqueue(StubRequestSession.Stub(statusCode: 200))
        await viewModel.remove(target)

        #expect(viewModel.removeError == nil)
        #expect(viewModel.entries.count == 1)
        #expect(viewModel.state == .loaded)
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
            body: Data(Fixtures.binResponseJSON.utf8)
        ))
        await viewModel.refresh()

        #expect(viewModel.state == .loaded)
        #expect(store.saveCalls.count == 1)
        // The persisted snapshot carries both fixture rows, keyed by album id.
        #expect(Set(store.saveCalls[0].map(\.id)) == [100, 200])
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

    /// Two WXYC-representative bin entries modelling a previously-persisted
    /// snapshot, stored in the arbitrary order the server handed them over —
    /// mirroring the `binResponseJSON` fixture, so the shelf sort is what puts
    /// Molina first on load.
    static let persistedEntries: [BinEntry] = [
        BinEntry(
            albumId: 200,
            albumTitle: "On Your Own Love Again", artistName: "Jessica Pratt",
            alphabeticalName: "Pratt, Jessica", label: "Drag City",
            codeLetters: "PRA", codeArtistNumber: 1, codeNumber: 5,
            formatName: "LP", genreName: "Rock"
        ),
        BinEntry(
            albumId: 100,
            albumTitle: "DOGA", artistName: "Juana Molina",
            alphabeticalName: "Molina, Juana", label: "Sonamos",
            codeLetters: "MOL", codeArtistNumber: 1, codeNumber: 12,
            formatName: "CD", genreName: "Rock"
        ),
    ]
}
