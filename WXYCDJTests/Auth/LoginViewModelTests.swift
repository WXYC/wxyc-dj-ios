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
//  Issue #100 adds the code path this screen now leads with: the stage machine,
//  the input-time digit normalization, the resend cooldown, and — the one that
//  spans both credentials — that switching stages retires a stale error so OTP
//  copy can never sit under the password form.
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

    // MARK: - Code sign-in (issue #100)

    /// The screen opens on the code path, not the password one.
    @Test func theCodePathIsWhereTheScreenStarts() {
        let viewModel = LoginViewModel(auth: makeAuth(session: StubRequestSession()))

        #expect(viewModel.stage == .identifier)
    }

    /// A username is resolved server-side, and what comes back is deliberately
    /// **not** shown: the lookup is an enumeration vector Backend-Service accepts
    /// only because it is rate-limited, so rendering its answer would put an
    /// address the DJ never typed on screen.
    @Test func ausernameAdvancesToTheCodeStepWithoutDisclosingTheAddress() async throws {
        let session = StubRequestSession()
        let viewModel = LoginViewModel(auth: makeAuth(session: session))
        viewModel.identifier = "  juana \n"

        session.enqueue(StubRequestSession.Stub(statusCode: 200, body: Data(#"{"email":"juana@wxyc.org"}"#.utf8)))
        session.enqueue(StubRequestSession.Stub(statusCode: 200, body: Data(#"{"success":true}"#.utf8)))

        await viewModel.requestCode()

        // The verify call is keyed on the resolved address...
        #expect(viewModel.stage == .awaitingCode(email: "juana@wxyc.org", displayTarget: "your registered email"))
        #expect(viewModel.sendError == nil)
        // ...and the identifier was trimmed before it went out.
        let lookup = try #require(session.recordedRequests.first)
        let lookupBody = try #require(lookup.httpBody)
        let payload = try #require(try JSONSerialization.jsonObject(with: lookupBody) as? [String: Any])
        #expect(payload["identifier"] as? String == "juana")
    }

    /// A typed email *is* echoed back — it is the DJ's only way to catch their
    /// own typo, since the server reports "code sent" for an address matching no
    /// account and the verify step is deliberately indistinguishable from a wrong
    /// code.
    @Test func atypedEmailIsShownBackToTheDJ() async throws {
        let session = StubRequestSession()
        let viewModel = LoginViewModel(auth: makeAuth(session: session))
        viewModel.identifier = "juana@wxyc.org"
        session.enqueue(StubRequestSession.Stub(statusCode: 200, body: Data(#"{"success":true}"#.utf8)))

        await viewModel.requestCode()

        #expect(viewModel.stage == .awaitingCode(email: "juana@wxyc.org", displayTarget: "juana@wxyc.org"))
        #expect(session.recordedRequests.count == 1)  // no lookup for an email
    }

    /// A failed request keeps the DJ on the identifier step with a reason. It
    /// must land in `sendError`, not `auth.lastError` — `sendLoginCode`
    /// establishes no session and so never sets the latter.
    @Test func afailedRequestStaysOnTheIdentifierStepWithAReason() async throws {
        let session = StubRequestSession()
        let auth = makeAuth(session: session)
        let viewModel = LoginViewModel(auth: auth)
        viewModel.identifier = "nobody"
        session.enqueue(StubRequestSession.Stub(statusCode: 200, body: Data(#"{"email":null}"#.utf8)))

        await viewModel.requestCode()

        #expect(viewModel.stage == .identifier)
        #expect(viewModel.sendError == "No account matches that username.")
        #expect(auth.lastError == nil)
        #expect(viewModel.isSendingCode == false)
    }

    /// A thrown transport failure is surfaced too, not swallowed.
    @Test func anOfflineRequestSurfacesRatherThanSilentlyFailing() async throws {
        let session = StubRequestSession()
        let viewModel = LoginViewModel(auth: makeAuth(session: session))
        viewModel.identifier = "juana@wxyc.org"
        session.enqueue(failure: URLError(.notConnectedToInternet))

        await viewModel.requestCode()

        #expect(viewModel.stage == .identifier)
        #expect(viewModel.sendError != nil)
    }

    /// Non-digits are dropped and the length capped as the DJ types, so a code
    /// pasted out of a mail client works. Safe because the server's alphabet is
    /// provably `0-9`.
    @Test(arguments: [
        ("12 34 56", "123456"),
        ("123-456", "123456"),
        ("12345678", "123456"),
        ("abc123", "123"),
    ])
    func thecodeFieldNormalizesAsItIsTyped(typed: String, expected: String) {
        let viewModel = LoginViewModel(auth: makeAuth(session: StubRequestSession()))

        viewModel.code = typed

        #expect(viewModel.code == expected)
    }

    @Test func submittingIsGatedOnASixDigitCode() {
        let viewModel = LoginViewModel(auth: makeAuth(session: StubRequestSession()))

        viewModel.code = "123"
        #expect(viewModel.canSubmitCode == false)
        viewModel.code = "123456"
        #expect(viewModel.canSubmitCode == true)
    }

    /// The resend cooldown is measured on a monotonic clock the test drives, so
    /// nothing here sleeps. 30s sits inside better-auth's 3-per-60s allowance.
    @Test func resendIsGatedUntilTheCooldownElapses() async throws {
        let session = StubRequestSession()
        let clock = ManualClock()
        let viewModel = LoginViewModel(
            auth: makeAuth(session: session),
            resendCooldown: .seconds(30),
            now: { clock.now }
        )
        viewModel.identifier = "juana@wxyc.org"
        session.enqueue(StubRequestSession.Stub(statusCode: 200, body: Data(#"{"success":true}"#.utf8)))

        #expect(viewModel.canResendCode == true)  // nothing sent yet
        await viewModel.requestCode()
        #expect(viewModel.canResendCode == false)

        clock.advance(by: .seconds(29))
        #expect(viewModel.canResendCode == false)

        clock.advance(by: .seconds(1))
        #expect(viewModel.canResendCode == true)

        // And a resend actually re-requests.
        session.enqueue(StubRequestSession.Stub(statusCode: 200, body: Data(#"{"success":true}"#.utf8)))
        await viewModel.resendCode()
        #expect(session.recordedRequests.count == 2)
    }

    /// The defect this guards: `auth.lastError` is cleared only when a sign-in
    /// begins or a sign-out completes, so a failed code verify would still be set
    /// when the DJ taps "Sign in with password instead" — rendering "That code
    /// isn't right" under a form that never produced a code.
    @Test func switchingToThePasswordFormRetiresTheCodeError() async throws {
        let session = StubRequestSession()
        let auth = makeAuth(session: session)
        let viewModel = LoginViewModel(auth: auth)
        viewModel.identifier = "juana@wxyc.org"

        session.enqueue(StubRequestSession.Stub(statusCode: 200, body: Data(#"{"success":true}"#.utf8)))
        await viewModel.requestCode()

        session.enqueue(StubRequestSession.Stub(
            statusCode: 400,
            body: Data(#"{"message":"Invalid OTP","code":"INVALID_OTP"}"#.utf8)
        ))
        viewModel.code = "000000"
        await viewModel.submitCode()
        #expect(auth.lastError != nil)

        viewModel.usePassword()

        #expect(viewModel.stage == .password)
        #expect(auth.lastError == nil)
        #expect(viewModel.sendError == nil)
    }

    /// Backing out to fix a mistyped identifier is the only recourse for a
    /// typo'd *email*, which the server cannot report.
    @Test func changingIdentifierReturnsToTheStartAndDropsTheCode() async throws {
        let session = StubRequestSession()
        let viewModel = LoginViewModel(auth: makeAuth(session: session))
        viewModel.identifier = "juana@wxyc.org"
        session.enqueue(StubRequestSession.Stub(statusCode: 200, body: Data(#"{"success":true}"#.utf8)))
        await viewModel.requestCode()
        viewModel.code = "123456"

        viewModel.changeIdentifier()

        #expect(viewModel.stage == .identifier)
        #expect(viewModel.code == "")
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

/// A hand-driven monotonic clock, so the resend-cooldown test asserts an
/// elapsed interval without sleeping for it. `ContinuousClock.Instant` rather
/// than `Date` because the cooldown measures elapsed time — the same reason
/// `ConnectivityMonitor` injects its probe clock this way.
private final class ManualClock: @unchecked Sendable {
    private let lock = OSAllocatedUnfairLock<ContinuousClock.Instant>(initialState: ContinuousClock.now)

    var now: ContinuousClock.Instant { lock.withLock { $0 } }

    func advance(by duration: Duration) {
        lock.withLock { $0 = $0.advanced(by: duration) }
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
