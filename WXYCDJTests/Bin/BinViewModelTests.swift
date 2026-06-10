//
//  BinViewModelTests.swift
//  WXYCDJTests
//
//  Pins BinViewModel's full lifecycle: refresh success (entries sorted
//  newest-first), refresh failure transitions to .error, remove success
//  drops the row, and remove failure populates `removeError` without
//  blowing the loaded list away (the surface added in PR #4).
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
}
