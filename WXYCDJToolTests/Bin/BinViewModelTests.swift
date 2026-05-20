//
//  BinViewModelTests.swift
//  WXYCDJToolTests
//
//  Pins the BinViewModel.remove failure path: an in-flight DELETE error must
//  populate `removeError` (so BinView's alert fires) without clobbering
//  `state` (which would blow the loaded list away) or optimistically removing
//  the row. Regression test for the surface added in PR #4.
//
//  Created by Jake on 5/19/26.
//  Copyright © 2026 WXYC. All rights reserved.
//

import Foundation
import Testing
@testable import WXYCAPI
@testable import WXYCDJTool

@Suite("BinViewModel", .serialized)
@MainActor
struct BinViewModelTests {
    private static let config = WXYCAPIConfiguration.localDevelopment

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

    @Test func removeFailurePreservesEntriesAndPopulatesRemoveError() async throws {
        let (client, session) = try await Self.makeSignedInClient()
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
