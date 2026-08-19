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

    private func makeAuth(session: any RequestSession) -> AuthService {
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
        #expect(viewModel.stage == .awaitingCode(LoginCodeDestination(email: "juana@wxyc.org", typedEmail: nil)))
        #expect(viewModel.displayedError == nil)
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

        #expect(viewModel.stage == .awaitingCode(LoginCodeDestination(email: "juana@wxyc.org", typedEmail: "juana@wxyc.org")))
        #expect(session.recordedRequests.count == 1)  // no lookup for an email
    }

    /// A failed request keeps the DJ on the identifier step with a reason.
    /// `sendLoginCode` records it in `lastError` before rethrowing — the same
    /// field `signIn` mutates — so the screen has one error surface rather than
    /// two that have to be coalesced.
    @Test func afailedRequestStaysOnTheIdentifierStepWithAReason() async throws {
        let session = StubRequestSession()
        let auth = makeAuth(session: session)
        let viewModel = LoginViewModel(auth: auth)
        viewModel.identifier = "nobody"
        session.enqueue(StubRequestSession.Stub(statusCode: 200, body: Data(#"{"email":null}"#.utf8)))

        await viewModel.requestCode()

        #expect(viewModel.stage == .identifier)
        #expect(viewModel.displayedError == "No account matches that username.")
        // Recorded on AuthService, not a second store: one reporting convention
        // for every credential route.
        #expect(auth.lastError == .rejected(message: "No account matches that username"))
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
        #expect(viewModel.displayedError != nil)
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

    /// The cooldown must actually *reopen* on screen. It is observable state
    /// flipped by a task, not a clock read: SwiftUI re-renders on mutation, and
    /// time passing is not one — an earlier clock-based version left the button
    /// latched disabled until some unrelated edit happened to invalidate the
    /// view, which is worst right after `TOO_MANY_ATTEMPTS` tells the DJ to
    /// "Request a new code".
    @Test func theResendWindowClosesThenReopensOnItsOwn() async throws {
        let session = StubRequestSession()
        let sleeper = ManualSleeper()
        let viewModel = LoginViewModel(
            auth: makeAuth(session: session),
            sleep: { await sleeper.sleep($0) }
        )
        viewModel.identifier = "juana@wxyc.org"
        session.enqueue(StubRequestSession.Stub(statusCode: 200, body: Data(#"{"success":true}"#.utf8)))

        #expect(viewModel.canResendCode == true)  // nothing sent yet
        await viewModel.requestCode()
        #expect(viewModel.canResendCode == false)

        sleeper.elapse()
        await waitUntil { viewModel.canResendCode }
        #expect(viewModel.canResendCode == true)

        session.enqueue(StubRequestSession.Stub(statusCode: 200, body: Data(#"{"success":true}"#.utf8)))
        await viewModel.resendCode()
        #expect(session.recordedRequests.count == 2)
    }

    /// A failed resend must be visible, and must not blank the screen.
    ///
    /// The failure mode this pins: the DJ mistypes a code, sees "That code isn't
    /// right.", taps "Send a new code", and the send 429s. `sendLoginCode` clears
    /// `lastError` on entry, so if the failure did not land back in that same
    /// field the DJ would watch the existing error *disappear* with nothing
    /// taking its place.
    @Test func afailedResendReplacesTheErrorOnScreenRatherThanErasingIt() async throws {
        let session = StubRequestSession()
        let auth = makeAuth(session: session)
        let sleeper = ManualSleeper()
        let viewModel = LoginViewModel(auth: auth, sleep: { await sleeper.sleep($0) })
        viewModel.identifier = "juana@wxyc.org"

        session.enqueue(StubRequestSession.Stub(statusCode: 200, body: Data(#"{"success":true}"#.utf8)))
        await viewModel.requestCode()

        // A wrong code first.
        session.enqueue(StubRequestSession.Stub(
            statusCode: 400,
            body: Data(#"{"message":"Invalid OTP","code":"INVALID_OTP"}"#.utf8)
        ))
        viewModel.code = "000000"
        await viewModel.submitCode()
        #expect(viewModel.displayedError == "That code isn't right. Check it and try again.")

        // Then a resend that is rate-limited.
        sleeper.elapse()
        await waitUntil { viewModel.canResendCode }
        session.enqueue(StubRequestSession.Stub(statusCode: 429, body: Data(#"{"error":"Too many requests"}"#.utf8)))
        await viewModel.resendCode()

        #expect(viewModel.displayedError == "Too many attempts. Wait a few minutes and try again.")
    }

    /// Backing out to the identifier stage must not refill the budget. The
    /// cooldown protects a **per-IP** allowance the control room shares, so
    /// "Send login code → Use a different account → Send login code" would
    /// otherwise loop unlimited sends straight past it.
    @Test func changingIdentifierDoesNotBypassTheCooldown() async throws {
        let session = StubRequestSession()
        let sleeper = ManualSleeper()
        let viewModel = LoginViewModel(auth: makeAuth(session: session), sleep: { await sleeper.sleep($0) })
        viewModel.identifier = "juana@wxyc.org"
        session.enqueue(StubRequestSession.Stub(statusCode: 200, body: Data(#"{"success":true}"#.utf8)))
        await viewModel.requestCode()

        viewModel.changeIdentifier()
        viewModel.identifier = "jessica@wxyc.org"

        #expect(viewModel.stage == .identifier)
        #expect(viewModel.canRequestCode == false)  // still inside the window

        await viewModel.requestCode()
        #expect(session.recordedRequests.count == 1)  // guarded, no second send
    }

    /// Verifying must not race an in-flight resend. Backend-Service configures
    /// no `resendStrategy`, so a resend mints a *fresh* OTP and overwrites the
    /// stored verification value — submitting the first mail's code mid-resend
    /// comes back `INVALID_OTP` for a code the DJ read correctly, and spends one
    /// of the 5 allowed attempts doing it.
    @Test func signInIsBlockedWhileAResendIsInFlight() async throws {
        let session = StubRequestSession()
        let sleeper = ManualSleeper()
        let viewModel = LoginViewModel(auth: makeAuth(session: session), sleep: { await sleeper.sleep($0) })
        viewModel.identifier = "juana@wxyc.org"
        session.enqueue(StubRequestSession.Stub(statusCode: 200, body: Data(#"{"success":true}"#.utf8)))
        await viewModel.requestCode()
        viewModel.code = "123456"
        #expect(viewModel.canSubmitCode == true)

        sleeper.elapse()
        await waitUntil { viewModel.canResendCode }

        // Park the resend mid-flight and check the gate closed.
        let blocking = HangingRequestSession()
        let blockedViewModel = LoginViewModel(auth: makeAuth(session: blocking), sleep: { await sleeper.sleep($0) })
        blockedViewModel.identifier = "juana@wxyc.org"
        let inFlight = Task { await blockedViewModel.requestCode() }
        await blocking.waitForFirstRequest()
        blockedViewModel.code = "123456"

        #expect(blockedViewModel.isSendingCode == true)
        #expect(blockedViewModel.canSubmitCode == false)

        inFlight.cancel()
        _ = await inFlight.value
    }

    /// The identifier stage is now the *first* screen a bounced-out DJ sees, so
    /// it has to render an error raised somewhere else entirely. `currentJWT`'s
    /// 401 demotion sets `.notSignedIn` on its way to swapping `MainView` for
    /// `LoginView`; a stage rendering only its own failures would greet a
    /// mid-shift revocation in silence.
    @Test func theFirstStageStillExplainsASessionThatDiedElsewhere() async throws {
        let session = StubRequestSession()
        let auth = makeAuth(session: session)
        let viewModel = LoginViewModel(auth: auth)

        // A sign-in failure is the reachable way to set lastError from a test;
        // the 401 demotion sets the same field by the same route.
        session.enqueue(StubRequestSession.Stub(statusCode: 401, body: Data("{}".utf8)))
        viewModel.identifier = "juana"
        viewModel.password = "wrong"
        await viewModel.submit()

        #expect(viewModel.stage == .identifier)
        #expect(viewModel.displayedError == auth.lastError?.localizedMessage)
        #expect(viewModel.displayedError != nil)
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
        #expect(viewModel.displayedError == nil)
    }

    /// A resend must not re-run the username lookup. The resolved address is
    /// already in the stage and cannot have changed — the identifier field isn't
    /// even on screen — so re-asking would spend two slots of a per-IP budget the
    /// control room shares, in exactly the moment a DJ taps most.
    @Test func resendingSkipsTheLookupItAlreadyPaidFor() async throws {
        let session = StubRequestSession()
        let sleeper = ManualSleeper()
        let viewModel = LoginViewModel(auth: makeAuth(session: session), sleep: { await sleeper.sleep($0) })
        viewModel.identifier = "juana"

        session.enqueue(StubRequestSession.Stub(statusCode: 200, body: Data(#"{"email":"juana@wxyc.org"}"#.utf8)))
        session.enqueue(StubRequestSession.Stub(statusCode: 200, body: Data(#"{"success":true}"#.utf8)))
        await viewModel.requestCode()
        #expect(session.recordedRequests.count == 2)  // lookup + send

        sleeper.elapse()
        await waitUntil { viewModel.canResendCode }
        session.enqueue(StubRequestSession.Stub(statusCode: 200, body: Data(#"{"success":true}"#.utf8)))
        await viewModel.resendCode()

        #expect(session.recordedRequests.count == 3)  // one send, no second lookup
        let resend = try #require(session.recordedRequests.last)
        #expect(resend.url?.path.hasSuffix("/auth/email-otp/send-verification-otp") == true)
        // And it still goes to the resolved address, which was never rendered.
        let body = try #require(resend.httpBody)
        let payload = try #require(try JSONSerialization.jsonObject(with: body) as? [String: Any])
        #expect(payload["email"] as? String == "juana@wxyc.org")
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

    // MARK: - Issue #106: error reporting

    /// `submit()` reports a `.missingSessionToken` (a 2xx sign-in response
    /// with neither a `set-auth-token` header nor a body token — the
    /// server's contract broke) but not `.invalidCredentials` (a wrong
    /// password, which the DJ can act on).
    @Test func submitReportsServerDefectsButNotInvalidCredentials() async throws {
        let session = StubRequestSession()
        let auth = makeAuth(session: session)
        let spy = SpyErrorReporter()
        let viewModel = LoginViewModel(auth: auth, reporter: spy)
        viewModel.identifier = "juana"
        viewModel.password = "hunter2"

        session.enqueue(StubRequestSession.Stub(statusCode: 200))  // no token anywhere
        await viewModel.submit()
        #expect(auth.lastError == .missingSessionToken)
        #expect(spy.reportCount == 1)
        #expect(spy.reports.first?.context == "LoginViewModel")

        session.enqueue(StubRequestSession.Stub(statusCode: 401))
        await viewModel.submit()
        #expect(auth.lastError == .invalidCredentials)
        #expect(spy.reportCount == 1)  // unchanged -- the second leg is a skip
    }

    /// Same report/skip split as `submit()`, over the code-sign-in leg.
    @Test func submitCodeReportsServerDefectsButNotInvalidCredentials() async throws {
        let session = StubRequestSession()
        let auth = makeAuth(session: session)
        let spy = SpyErrorReporter()
        let viewModel = LoginViewModel(auth: auth, reporter: spy)
        viewModel.identifier = "juana@wxyc.org"

        session.enqueue(StubRequestSession.Stub(statusCode: 200, body: Data(#"{"success":true}"#.utf8)))
        await viewModel.requestCode()
        viewModel.code = "123456"

        session.enqueue(StubRequestSession.Stub(statusCode: 200))  // no token anywhere
        await viewModel.submitCode()
        #expect(auth.lastError == .missingSessionToken)
        #expect(spy.reportCount == 1)
        #expect(spy.reports.first?.context == "LoginViewModel")

        session.enqueue(StubRequestSession.Stub(statusCode: 401))
        await viewModel.submitCode()
        #expect(auth.lastError == .invalidCredentials)
        #expect(spy.reportCount == 1)  // unchanged
    }

    /// `requestCode()` reports a `.serverFailure` but not a `.rateLimited` —
    /// the latter is reachable in ordinary use (the control room shares an
    /// egress address), not a defect.
    @Test func requestCodeReportsServerFailureButNotRateLimit() async throws {
        let session = StubRequestSession()
        // requestCode() starts the resend cooldown unconditionally on every
        // call (success or failure), so a second call needs the cooldown
        // driven forward -- same pattern as the existing cooldown tests.
        let sleeper = ManualSleeper()
        let auth = makeAuth(session: session)
        let spy = SpyErrorReporter()
        let viewModel = LoginViewModel(auth: auth, reporter: spy, sleep: { await sleeper.sleep($0) })
        viewModel.identifier = "juana@wxyc.org"  // an email skips the lookup leg

        session.enqueue(StubRequestSession.Stub(statusCode: 500, body: Data(#"{"error":"boom"}"#.utf8)))
        await viewModel.requestCode()
        #expect(spy.reportCount == 1)
        #expect(spy.reports.first?.context == "LoginViewModel")

        sleeper.elapse()
        await waitUntil { viewModel.canRequestCode }

        session.enqueue(StubRequestSession.Stub(statusCode: 429, body: Data(#"{"error":"Too many requests"}"#.utf8)))
        await viewModel.requestCode()
        #expect(spy.reportCount == 1)  // unchanged -- rate limiting is not a defect
    }

    /// **`resendCode()` is the case this issue exists to catch.**
    /// `try? await auth.resendLoginCode(...)` swallows the throw entirely —
    /// there is no caller left to see it fail — but `AuthService` still lands
    /// the failure in `lastError`, and that must still reach the reporter.
    /// Before issue #106 this class of defect (a resend 500ing) was
    /// invisible everywhere: not thrown, not logged, not reported.
    @Test func resendCodeReportsServerFailureButNotRateLimit() async throws {
        let session = StubRequestSession()
        let sleeper = ManualSleeper()
        let auth = makeAuth(session: session)
        let spy = SpyErrorReporter()
        let viewModel = LoginViewModel(auth: auth, reporter: spy, sleep: { await sleeper.sleep($0) })
        viewModel.identifier = "juana@wxyc.org"

        session.enqueue(StubRequestSession.Stub(statusCode: 200, body: Data(#"{"success":true}"#.utf8)))
        await viewModel.requestCode()
        sleeper.elapse()
        await waitUntil { viewModel.canResendCode }

        session.enqueue(StubRequestSession.Stub(statusCode: 500, body: Data(#"{"error":"boom"}"#.utf8)))
        await viewModel.resendCode()
        // The throw never reached this call site (resendCode() doesn't
        // rethrow), but the defect still reported.
        #expect(spy.reportCount == 1)
        #expect(spy.reports.first?.context == "LoginViewModel")

        sleeper.elapse()
        await waitUntil { viewModel.canResendCode }
        session.enqueue(StubRequestSession.Stub(statusCode: 429, body: Data(#"{"error":"Too many requests"}"#.utf8)))
        await viewModel.resendCode()
        #expect(spy.reportCount == 1)  // unchanged -- rate limiting is not a defect
    }

    // MARK: - Issue #106 review Fix 6: the pending-JWT window

    /// A transient `GET /auth/token` failure right after a successful
    /// password sign-in leaves `auth.state` in the issue-#53 pending window
    /// rather than `lastError` -- `reportIfDefect()` alone has nothing to
    /// read, so this outcome would otherwise be reported nowhere, silently
    /// contradicting the PR's own capture-site table.
    @Test func submitReportsAPendingJWTWindowAfterATransientTokenFailure() async throws {
        let session = StubRequestSession()
        let auth = makeAuth(session: session)
        let spy = SpyErrorReporter()
        let viewModel = LoginViewModel(auth: auth, reporter: spy)
        viewModel.identifier = "juana"
        viewModel.password = "hunter2"

        session.enqueue(StubRequestSession.Stub(statusCode: 200, headers: Self.signInSuccessHeaders))
        session.enqueue(StubRequestSession.Stub(statusCode: 503, body: Data(#"{"error":"boom"}"#.utf8)))

        await viewModel.submit()

        #expect(auth.state == .signedIn(payload: nil))
        #expect(auth.lastError == nil)  // the pending window is not an AuthError
        #expect(spy.reportCount == 1)
        #expect(spy.reports.first?.context == "LoginViewModel.pendingJWT")
    }

    /// Same shape, over the code-sign-in leg.
    @Test func submitCodeReportsAPendingJWTWindowAfterATransientTokenFailure() async throws {
        let session = StubRequestSession()
        let auth = makeAuth(session: session)
        let spy = SpyErrorReporter()
        let viewModel = LoginViewModel(auth: auth, reporter: spy)
        viewModel.identifier = "juana@wxyc.org"

        session.enqueue(StubRequestSession.Stub(statusCode: 200, body: Data(#"{"success":true}"#.utf8)))
        await viewModel.requestCode()
        viewModel.code = "123456"

        session.enqueue(StubRequestSession.Stub(statusCode: 200, headers: Self.signInSuccessHeaders))
        session.enqueue(StubRequestSession.Stub(statusCode: 503, body: Data(#"{"error":"boom"}"#.utf8)))

        await viewModel.submitCode()

        #expect(auth.state == .signedIn(payload: nil))
        #expect(auth.lastError == nil)
        #expect(spy.reportCount == 1)
        #expect(spy.reports.first?.context == "LoginViewModel.pendingJWT")
    }

    /// A fully successful sign-in (both legs land) reports nothing -- the
    /// pending-window report must not fire on the ordinary path.
    @Test func submitDoesNotReportAPendingJWTWindowOnAFullSuccess() async throws {
        let session = StubRequestSession()
        let auth = makeAuth(session: session)
        let spy = SpyErrorReporter()
        let viewModel = LoginViewModel(auth: auth, reporter: spy)
        viewModel.identifier = "juana"
        viewModel.password = "hunter2"

        session.enqueue(StubRequestSession.Stub(statusCode: 200, headers: Self.signInSuccessHeaders))
        session.enqueue(StubRequestSession.Stub(
            statusCode: 200,
            body: Data(#"{"token":"\#(Fixtures.jwt())"}"#.utf8)
        ))

        await viewModel.submit()

        #expect(spy.reportCount == 0)
    }
}

/// Pins `LoginViewModel.shouldReport(_:)` — the total switch over every
/// `AuthError` case — as a standalone table, independent of driving all four
/// sign-in legs over the network for every case. The leg-specific tests above
/// (`LoginViewModelTests`) confirm the wiring actually calls this at each of
/// the four call sites; this confirms the classification itself is complete
/// and correct, so a future `AuthError` case is a compile-time decision here
/// rather than a silent miss.
@Suite("LoginViewModel.shouldReport")
struct LoginViewModelShouldReportTests {
    @Test(arguments: [
        (AuthError.invalidCredentials, false),
        (AuthError.network(message: "boom"), true),
        (AuthError.offline(message: "offline"), false),
        (AuthError.missingSessionToken, true),
        (AuthError.serverFailure(status: 500, message: nil), true),
        (AuthError.rejected(message: nil), false),
        (AuthError.rateLimited, false),
        (AuthError.notSignedIn, true),
    ])
    func classifiesEveryAuthErrorCase(error: AuthError, shouldReport: Bool) {
        #expect(LoginViewModel.shouldReport(error) == shouldReport)
    }
}

/// A hand-driven stand-in for `Task.sleep`, so the resend-cooldown tests assert
/// the window opening and closing without waiting 30 real seconds.
///
/// `elapse()` is tolerant of ordering — if it lands before the view model's task
/// reaches the sleep, the release is latched — so a test never depends on
/// winning a race with the task it just started.
private final class ManualSleeper: @unchecked Sendable {
    private struct State {
        var waiter: CheckedContinuation<Void, Never>?
        var latched = false
    }

    private let lock = OSAllocatedUnfairLock<State>(initialState: State())

    func sleep(_ duration: Duration) async {
        await withCheckedContinuation { continuation in
            let resumeNow = lock.withLock { state -> Bool in
                if state.latched {
                    state.latched = false
                    return true
                }
                state.waiter = continuation
                return false
            }
            if resumeNow { continuation.resume() }
        }
    }

    /// Let the pending cooldown finish.
    func elapse() {
        let waiter = lock.withLock { state -> CheckedContinuation<Void, Never>? in
            if let waiter = state.waiter {
                state.waiter = nil
                return waiter
            }
            state.latched = true
            return nil
        }
        waiter?.resume()
    }
}

/// Spin the main actor until `condition` holds, so a test can observe state a
/// detached-in-time task sets without sleeping.
@MainActor
private func waitUntil(_ condition: () -> Bool) async {
    for _ in 0..<1_000 where !condition() {
        await Task.yield()
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
