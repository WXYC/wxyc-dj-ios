//
//  LoginViewModelTests.swift
//  WXYCDJToolTests
//
//  Pins LoginViewModel: canSubmit gates on field+auth state, submit() trims
//  whitespace on the username (not the password) before forwarding to
//  AuthService, and a guarded submit() with empty fields is a no-op.
//
//  Created by Jake on 5/20/26.
//  Copyright © 2026 WXYC. All rights reserved.
//

import Foundation
import Testing
@testable import WXYCAPI
@testable import WXYCDJTool

@Suite("LoginViewModel", .serialized)
@MainActor
struct LoginViewModelTests {
    private static let signInSuccessHeaders = ["set-auth-token": "session-abc"]

    private func makeAuth(session: StubRequestSession) -> AuthService {
        AuthService(
            configuration: .localDevelopment,
            storage: InMemoryTokenStorage(),
            session: session
        )
    }

    @Test func canSubmitFalseWhenUsernameEmpty() {
        let session = StubRequestSession()
        let viewModel = LoginViewModel(auth: makeAuth(session: session))
        viewModel.password = "hunter2"

        #expect(viewModel.canSubmit == false)
    }

    @Test func canSubmitFalseWhenPasswordEmpty() {
        let session = StubRequestSession()
        let viewModel = LoginViewModel(auth: makeAuth(session: session))
        viewModel.username = "juana"

        #expect(viewModel.canSubmit == false)
    }

    @Test func canSubmitTrueWhenBothFieldsPopulated() {
        let session = StubRequestSession()
        let viewModel = LoginViewModel(auth: makeAuth(session: session))
        viewModel.username = "juana"
        viewModel.password = "hunter2"

        #expect(viewModel.canSubmit == true)
    }

    @Test func submitTrimsUsernameWhitespaceButPreservesPassword() async throws {
        let session = StubRequestSession()
        let auth = makeAuth(session: session)
        let viewModel = LoginViewModel(auth: auth)
        viewModel.username = "  juana \n"
        viewModel.password = "  hunter2 "

        session.enqueue(StubRequestSession.Stub(statusCode: 200, headers: Self.signInSuccessHeaders))
        session.enqueue(StubRequestSession.Stub(
            statusCode: 200,
            body: Data(#"{"token":"\#(Fixtures.jwt())"}"#.utf8)
        ))

        await viewModel.submit()

        let signInRequest = try #require(session.recordedRequests.first)
        let body = try #require(signInRequest.httpBody)
        let payload = try #require(try JSONSerialization.jsonObject(with: body) as? [String: Any])
        #expect(payload["username"] as? String == "juana")
        #expect(payload["password"] as? String == "  hunter2 ")
    }

    @Test func submitWithEmptyFieldsIsNoOp() async {
        let session = StubRequestSession()
        let viewModel = LoginViewModel(auth: makeAuth(session: session))

        await viewModel.submit()

        #expect(session.recordedRequests.isEmpty)
    }
}
