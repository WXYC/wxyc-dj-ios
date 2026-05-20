//
//  SearchViewModelTests.swift
//  WXYCDJToolTests
//
//  Pins SearchViewModel's outward state machine: short / empty queries stay
//  idle, a hit transitions to .results, an empty response to .empty, an HTTP
//  error to .error, and a follow-up keystroke that shortens the query below
//  the minimum length cancels the in-flight task and clears results without
//  hitting the network. The debounce *timing* is treated as an
//  implementation detail — we poll the state until it settles rather than
//  asserting against the wall clock.
//
//  Created by Jake on 5/20/26.
//  Copyright © 2026 WXYC. All rights reserved.
//

import Foundation
import Testing
@testable import WXYCAPI
@testable import WXYCDJTool

@Suite("SearchViewModel", .serialized)
@MainActor
struct SearchViewModelTests {
    @Test func emptyQueryStaysIdleAndIssuesNoRequest() async throws {
        let (client, session) = try await SignedInClient.make()
        let viewModel = SearchViewModel(api: client)
        let baseline = session.recordedRequests.count

        viewModel.query = ""
        try await Self.waitBriefly()

        #expect(viewModel.state == .idle)
        #expect(viewModel.results.isEmpty)
        #expect(session.recordedRequests.count == baseline)
    }

    @Test func singleCharQueryStaysIdleAndIssuesNoRequest() async throws {
        let (client, session) = try await SignedInClient.make()
        let viewModel = SearchViewModel(api: client)
        let baseline = session.recordedRequests.count

        viewModel.query = "j"
        try await Self.waitBriefly()

        #expect(viewModel.state == .idle)
        #expect(viewModel.results.isEmpty)
        #expect(session.recordedRequests.count == baseline)
    }

    @Test func hitTransitionsToResultsState() async throws {
        let (client, session) = try await SignedInClient.make()
        let viewModel = SearchViewModel(api: client)
        session.enqueue(StubRequestSession.Stub(
            statusCode: 200,
            body: Data(Fixtures.juanaMolinaSearchResultsJSON.utf8)
        ))

        viewModel.query = "ju"
        try await Self.waitForSettle(viewModel)

        #expect(viewModel.state == .results)
        #expect(viewModel.results.count == 1)
        #expect(viewModel.results.first?.artistName == "Juana Molina")
    }

    @Test func emptyResponseTransitionsToEmptyState() async throws {
        let (client, session) = try await SignedInClient.make()
        let viewModel = SearchViewModel(api: client)
        session.enqueue(StubRequestSession.Stub(statusCode: 200, body: Data("[]".utf8)))

        viewModel.query = "zzz"
        try await Self.waitForSettle(viewModel)

        #expect(viewModel.state == .empty)
        #expect(viewModel.results.isEmpty)
    }

    @Test func serverErrorTransitionsToErrorState() async throws {
        let (client, session) = try await SignedInClient.make()
        let viewModel = SearchViewModel(api: client)
        session.enqueue(StubRequestSession.Stub(statusCode: 500, body: Data(#"{"error":"boom"}"#.utf8)))

        viewModel.query = "ju"
        try await Self.waitForSettle(viewModel)

        if case .error = viewModel.state {
            // pass
        } else {
            Issue.record("expected .error state, got \(viewModel.state)")
        }
    }

    @Test func shorteningQueryBelowMinimumCancelsInFlightSearch() async throws {
        let (client, session) = try await SignedInClient.make()
        let viewModel = SearchViewModel(api: client)
        let baseline = session.recordedRequests.count

        viewModel.query = "ju"
        #expect(viewModel.state == .searching)

        // Drop below the 2-char minimum before the debounce fires. The pending
        // Task should be cancelled; state resets to .idle; nothing hits the
        // network.
        viewModel.query = "j"
        try await Self.waitBriefly()

        #expect(viewModel.state == .idle)
        #expect(viewModel.results.isEmpty)
        #expect(session.recordedRequests.count == baseline)
    }

    /// Sleep just long enough to be confident the debounce timer would have
    /// fired if it was going to. Used by the "should *not* fire" cases.
    private static func waitBriefly() async throws {
        try await Task.sleep(for: .milliseconds(500))
    }

    /// Poll until the view model leaves .searching, or 2 s elapses.
    private static func waitForSettle(_ viewModel: SearchViewModel) async throws {
        let deadline = Date().addingTimeInterval(2.0)
        while viewModel.state == .searching && Date() < deadline {
            try await Task.sleep(for: .milliseconds(25))
        }
    }
}
