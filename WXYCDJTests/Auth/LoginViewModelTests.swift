//
//  LoginViewModelTests.swift
//  WXYCDJTests
//
//  Pins LoginViewModel: canSubmit gates on field+auth state, submit() trims
//  whitespace on the identifier (not the password) before forwarding to
//  AuthService, and a guarded submit() with empty fields is a no-op. Since
//  issue #97 that identifier may be a username or an email, so the field's
//  pass-through is pinned for both.
//
//  Created by Jake on 5/20/26.
//  Copyright © 2026 WXYC. All rights reserved.
//

import Foundation
import os
import Testing
@testable import WXYCAPI
@testable import WXYCDJ

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

    @Test func canSubmitFalseWhenIdentifierEmpty() {
        let session = StubRequestSession()
        let viewModel = LoginViewModel(auth: makeAuth(session: session))
        viewModel.password = "hunter2"

        #expect(viewModel.canSubmit == false)
    }

    @Test func canSubmitFalseWhenPasswordEmpty() {
        let session = StubRequestSession()
        let viewModel = LoginViewModel(auth: makeAuth(session: session))
        viewModel.identifier = "juana"

        #expect(viewModel.canSubmit == false)
    }

    @Test func canSubmitFalseWhenIdentifierIsOnlyWhitespace() {
        // submit() trims, so a whitespace-only identifier would post an empty
        // one and come back "Incorrect username or email, or password" — a
        // credential verdict on a field the DJ never filled in. Gate on the
        // trimmed value so the button stays disabled instead.
        let session = StubRequestSession()
        let viewModel = LoginViewModel(auth: makeAuth(session: session))
        viewModel.identifier = "   \n "
        viewModel.password = "hunter2"

        #expect(viewModel.canSubmit == false)
    }

    @Test func canSubmitTrueWhenBothFieldsPopulated() {
        let session = StubRequestSession()
        let viewModel = LoginViewModel(auth: makeAuth(session: session))
        viewModel.identifier = "juana"
        viewModel.password = "hunter2"

        #expect(viewModel.canSubmit == true)
    }

    /// The view model's whole job on submit: trim the identifier, leave the
    /// password alone, forward. Driven with both credential kinds because the
    /// field takes either since issue #97 — the routing itself is `AuthService`'s
    /// business (and pinned there), so this asserts only that whichever kind the
    /// DJ typed arrives trimmed and intact on the route it belongs to.
    @Test(arguments: [
        ("  juana \n", "/auth/sign-in/username", "username", "juana"),
        (" juana@wxyc.org ", "/auth/sign-in/email", "email", "juana@wxyc.org"),
    ])
    func submitTrimsTheIdentifierButPreservesThePassword(
        typed: String,
        expectedPath: String,
        expectedKey: String,
        expectedIdentifier: String
    ) async throws {
        let session = StubRequestSession()
        let viewModel = LoginViewModel(auth: makeAuth(session: session))
        viewModel.identifier = typed
        viewModel.password = "  hunter2 "

        session.enqueue(StubRequestSession.Stub(statusCode: 200, headers: Self.signInSuccessHeaders))
        session.enqueue(StubRequestSession.Stub(
            statusCode: 200,
            body: Data(#"{"token":"\#(Fixtures.jwt())"}"#.utf8)
        ))

        await viewModel.submit()

        let signInRequest = try #require(session.recordedRequests.first)
        #expect(signInRequest.url?.path == expectedPath)
        let body = try #require(signInRequest.httpBody)
        let payload = try #require(try JSONSerialization.jsonObject(with: body) as? [String: Any])
        #expect(payload[expectedKey] as? String == expectedIdentifier)
        #expect(payload["password"] as? String == "  hunter2 ")
    }

    @Test func submitWithEmptyFieldsIsNoOp() async {
        let session = StubRequestSession()
        let viewModel = LoginViewModel(auth: makeAuth(session: session))

        await viewModel.submit()

        #expect(session.recordedRequests.isEmpty)
    }

    @Test func secondSubmitWhileSigningInIsNoOp() async throws {
        let session = HangingRequestSession()
        let auth = AuthService(
            configuration: .localDevelopment,
            storage: InMemoryTokenStorage(),
            session: session
        )
        let viewModel = LoginViewModel(auth: auth)
        viewModel.identifier = "juana"
        viewModel.password = "hunter2"

        let firstSubmit = Task { await viewModel.submit() }
        await session.waitForFirstRequest()

        #expect(auth.state == .signingIn)
        #expect(viewModel.canSubmit == false)

        await viewModel.submit()

        #expect(session.recordedRequests.count == 1)

        firstSubmit.cancel()
        _ = await firstSubmit.value
    }
}

/// RequestSession that records the inbound request, signals waiters, then
/// suspends until the surrounding task is cancelled. Lets a test pin the
/// view model while AuthService.signIn is parked at its first await.
private final class HangingRequestSession: RequestSession, @unchecked Sendable {
    private struct State {
        var recorded: [URLRequest] = []
        var waiter: CheckedContinuation<Void, Never>?
    }

    private let state = OSAllocatedUnfairLock<State>(initialState: State())

    var recordedRequests: [URLRequest] {
        state.withLock { $0.recorded }
    }

    func waitForFirstRequest() async {
        await withCheckedContinuation { continuation in
            let resumeImmediately = state.withLock { state -> Bool in
                if !state.recorded.isEmpty {
                    return true
                }
                state.waiter = continuation
                return false
            }
            if resumeImmediately {
                continuation.resume()
            }
        }
    }

    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        let waiter = state.withLock { state -> CheckedContinuation<Void, Never>? in
            state.recorded.append(request)
            return state.waiter.take()
        }
        waiter?.resume()
        // Sleep until cancelled — the test releases us via Task.cancel.
        try await Task.sleep(for: .seconds(60))
        throw CancellationError()
    }
}

extension Optional {
    fileprivate mutating func take() -> Wrapped? {
        let value = self
        self = nil
        return value
    }
}
