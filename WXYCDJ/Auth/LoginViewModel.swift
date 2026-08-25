//
//  LoginViewModel.swift
//  WXYCDJ
//
//  Owns the LoginView form fields and the two credentials it offers: a mailed
//  one-time code (the path the screen leads with) and a password. Lets the
//  stage machine and the trim/forward logic be unit-tested without driving the
//  view; mirrors the @Observable view-model pattern used by SearchViewModel.
//
//  Created by Jake on 5/20/26.
//  Copyright © 2026 WXYC. All rights reserved.
//

import Foundation
import Observation
import WXYCAPI

@MainActor
@Observable
final class LoginViewModel {
    /// Which credential the DJ is partway through presenting.
    ///
    /// An explicit stage rather than a pair of booleans, because the states are
    /// genuinely exclusive and two of them carry data. It does **not** decide
    /// which error the screen shows — that was an earlier design and it dropped
    /// messages in both directions; see ``displayedError``.
    enum Stage: Equatable {
        /// The default. One field; the DJ asks for a code.
        case identifier
        /// A code is in the DJ's inbox. Carries the destination whole rather than
        /// restating its two fields, so the "only `typedEmail` is renderable"
        /// rule stays a property of one type.
        case awaitingCode(LoginCodeDestination)
        /// The secondary path, reached by "Sign in with password instead".
        case password
    }

    /// The DJ's login identifier: a username **or** an email address, matching
    /// the single field dj.wxyc.org offers. `AuthService` routes the two — to
    /// different sign-in endpoints for a password (issue #97), and to a lookup or
    /// straight through for a code (issue #100); nothing here needs to know
    /// which, beyond handing over a trimmed value.
    var identifier: String = ""
    var password: String = ""

    private(set) var stage: Stage = .identifier

    /// True while `sendLoginCode` is in flight.
    ///
    /// Needed because that call deliberately never enters `AuthService`'s
    /// `.signingIn` state — it establishes no session — so `auth.state` cannot
    /// drive this step's spinner or disable its button. Two requests can be in
    /// flight here: the lookup, then the send.
    private(set) var isSendingCode = false

    /// Whether the resend cooldown is currently running.
    ///
    /// **Observable state, not a clock read.** An earlier version computed this
    /// as `now() - codeSentAt >= cooldown` over an injected `ContinuousClock`,
    /// which is correct arithmetic and a broken UI: SwiftUI re-evaluates a body
    /// when observable state changes, and the passage of time is not a mutation.
    /// The button latched disabled and came back only if some unrelated edit
    /// happened to invalidate the view — worst directly after
    /// `TOO_MANY_ATTEMPTS`, whose copy says "Request a new code" while the only
    /// button that can do so looks dead. A task that flips this flag when the
    /// window closes is what actually re-renders.
    private(set) var isResendOnCooldown = false

    private var cooldownTask: Task<Void, Never>?

    private let auth: AuthService
    private let sleep: @Sendable (Duration) async throws -> Void
    /// The app's error-reporting seam (issue #106). Defaults to
    /// ``NoOpErrorReporter`` so every existing test construction site keeps
    /// compiling unchanged; `LoginView` passes `deps.errorReporter`.
    private let reporter: any ErrorReporter
    /// The app's product-analytics seam (issue #108). Same default-to-no-op
    /// discipline as `reporter`; `LoginView` passes `deps.analytics`.
    private let analytics: any Analytics

    /// better-auth allows 3 sends per 60s on the send route, so 30 s leaves
    /// headroom (2/min) while still letting a DJ whose mail is slow try again
    /// without feeling stuck. It also protects the Express limiter's 10 per 15
    /// minutes, which is keyed per-**IP** — a budget the control room shares.
    static let defaultResendCooldown: Duration = .seconds(30)

    /// Only the sleeper is injectable. The cooldown *duration* had a seam too,
    /// and nothing ever used it — tests drive a manual sleeper that ignores the
    /// `Duration` entirely, so the parameter, the stored property, and its
    /// capture were all inert.
    init(
        auth: AuthService,
        reporter: any ErrorReporter = NoOpErrorReporter(),
        analytics: any Analytics = NoOpAnalytics(),
        sleep: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) }
    ) {
        self.auth = auth
        self.reporter = reporter
        self.analytics = analytics
        self.sleep = sleep
    }

    // No `deinit` cancel: a `@MainActor` class's deinit is nonisolated and cannot
    // touch `cooldownTask`. It doesn't need to — the task captures `self` weakly,
    // so it retains nothing, and it is bounded by the cooldown before it
    // no-ops. The cancel that matters is the one in `startResendCooldown`, which
    // retires a superseded window rather than letting two race.

    /// The one error the screen shows.
    ///
    /// A single source, because `AuthService` now reports every credential
    /// failure the same way — `sendLoginCode` records into `lastError` before
    /// rethrowing, exactly as `signIn` mutates it. An earlier design had the code
    /// request report *only* by throwing, which forced a second store here and a
    /// coalesce between them; that produced a real defect (a failed resend went
    /// unrendered *and* wiped the message already on screen, since `sendLoginCode`
    /// clears `lastError` on entry). One surface can't drift out of sync with
    /// itself.
    var displayedError: String? {
        auth.lastError?.localizedMessage
    }

    // MARK: - The code the DJ types

    private var codeStorage: String = ""

    /// The typed one-time code, normalized as it is entered.
    ///
    /// Non-digits are dropped and the length capped at 6, matching dj-site's
    /// `OTPCodeForm`. Safe because the server's alphabet is provably `0-9`
    /// (better-auth's `defaultOTPGenerator` is `generateRandomString(6, "0-9")`,
    /// and Backend-Service overrides `otpLength` but not `generateOTP`), so this
    /// can only ever discard characters a real code cannot contain — which is
    /// what lets a code pasted as "123 456" work.
    var code: String {
        get { codeStorage }
        set { codeStorage = String(newValue.filter(\.isNumber).prefix(6)) }
    }

    // MARK: - Gates

    private var trimmedIdentifier: String {
        identifier.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Gates on the *trimmed* identifier, matching what is actually sent — an
    /// all-whitespace field would otherwise post an empty identifier and come
    /// back as a verdict on a field the DJ never filled in.
    ///
    /// Also gated on the cooldown, which is not obvious: this is the button on
    /// the *first* stage, and "Send login code → Use a different account → Send
    /// login code" would otherwise loop unlimited sends straight past it. The
    /// budget the cooldown protects is per-IP, so switching accounts does not
    /// refill it — the gate has to follow the request, not the identifier.
    var canRequestCode: Bool {
        !trimmedIdentifier.isEmpty && !isSendingCode && !isResendOnCooldown
    }

    var canSubmit: Bool {
        !trimmedIdentifier.isEmpty && !password.isEmpty && auth.state != .signingIn
    }

    /// Blocked while a send is in flight, because a resend **replaces** the
    /// stored code rather than reusing it: Backend-Service configures no
    /// `resendStrategy`, so `resolveOTP` mints a fresh OTP and overwrites the
    /// verification value. Verifying the code from the first mail while the
    /// second is being minted races that write, comes back `INVALID_OTP` for a
    /// code the DJ read correctly, and burns one of the 5 `allowedAttempts`.
    var canSubmitCode: Bool {
        code.count == 6 && auth.state != .signingIn && !isSendingCode
    }

    /// Whether a fresh code may be requested yet.
    ///
    /// **Issue #118 item 5.** Also gated on `auth.state != .signingIn`, unlike
    /// an earlier version of this property — without it, Resend stayed live
    /// while `submitCode()`'s verify was in flight, so a resend that failed
    /// (a 429 is reachable from the control room's shared egress) while the
    /// verify succeeded could land its error in `auth.lastError` right as
    /// `settle(.otp)` read it, misattributing a resend failure as a sign-in
    /// failure — both to `sign_in_failed` (issue #108) and, via
    /// `reportIfDefect()`, to Sentry (issue #106; this predates #108). Mirrors
    /// `canSubmitCode`'s existing `auth.state != .signingIn` gate, just in the
    /// other direction: that one keeps a verify from racing a resend's
    /// in-flight OTP replacement, this one keeps a resend from racing a
    /// verify's in-flight outcome.
    var canResendCode: Bool {
        !isSendingCode && !isResendOnCooldown && auth.state != .signingIn
    }

    // MARK: - Error reporting (issue #106)

    /// Whether a recorded `AuthError` names a defect worth reporting to
    /// crash/error telemetry, as opposed to an expected user-facing outcome.
    ///
    /// A **total switch** on purpose — the same shape as `AuthError.caseName`
    /// and `APIError.caseName` in `WXYCAPI` — so a future case added to
    /// `AuthError` is a compile-time decision here, not a silent miss.
    ///
    /// Reported (something went wrong on our end, not the DJ's):
    /// - ``AuthError/serverFailure(status:message:)`` — the server answered
    ///   with a status this app has no specific handling for.
    /// - ``AuthError/missingSessionToken`` — a 2xx sign-in response carried
    ///   neither a `set-auth-token` header nor a body token; the server's
    ///   contract broke.
    /// - ``AuthError/network(message:)`` — a genuine transport defect (not
    ///   connectivity, which is split out as `.offline` at the package's
    ///   flatten sites — see `AuthService.classifyTransportFailure`).
    /// - ``AuthError/notSignedIn`` — a session freshly established by leg 1
    ///   of this very sign-in was immediately rejected on the JWT exchange.
    ///   Unlike the other places this case appears (a 401 demoting an
    ///   *existing* session, which is a normal expiry), here it means a
    ///   brand-new session died before the DJ ever got signed in — an
    ///   internal inconsistency, not a credential problem.
    ///
    /// Never reported (expected outcomes the DJ can act on, or a supported
    /// mode):
    /// - ``AuthError/invalidCredentials`` — wrong username/email or password.
    /// - ``AuthError/rateLimited`` — reachable in ordinary use (the control
    ///   room shares an egress address), not an abuse signal.
    /// - ``AuthError/rejected(message:)`` — the server named a reason the DJ
    ///   can act on (malformed email, unverified address, a stale code).
    /// - ``AuthError/offline(message:)`` — being offline is a supported mode
    ///   (issues #58/#81), never a defect.
    nonisolated static func shouldReport(_ error: AuthError) -> Bool {
        switch error {
        case .serverFailure, .missingSessionToken, .network, .notSignedIn:
            return true
        case .invalidCredentials, .rateLimited, .rejected, .offline:
            return false
        }
    }

    /// Report `auth.lastError` if it's both present and a reportable defect.
    ///
    /// Called after each of the four sign-in legs (`submit`, `submitCode`,
    /// `requestCode`, `resendCode`) settles. `AuthService` clears `lastError`
    /// at the *start* of `signIn`/`sendLoginCode`/`resendLoginCode`, so
    /// whatever is left here once the `await` returns is this call's own
    /// outcome — `nil` on success, never a stale value carried over from an
    /// earlier leg. Safe to call unconditionally: a `nil` (success) is a
    /// no-op.
    private func reportIfDefect() {
        guard let error = auth.lastError, Self.shouldReport(error) else { return }
        reporter.report(error, context: "LoginViewModel")
    }

    /// A synthetic error reported when a sign-in leg completes in the
    /// issue-#53 pending window — `.signedIn(payload: nil)`, a transient
    /// JWT-exchange failure (e.g. a `503` from `GET /auth/token`) that
    /// leaves the DJ signed in with no JWT until a lazy re-mint.
    ///
    /// Not an `AuthError` case: `AuthService` deliberately doesn't treat this
    /// as an error — it's a documented "session established, JWT pending"
    /// state, so `lastError` stays whatever it was cleared to at the start of
    /// `signIn` (`nil`, if leg 1 succeeded). `reportIfDefect()` therefore has
    /// nothing to read for this outcome. This type exists only because
    /// `ErrorReporter.report` requires `any Error`, and the pending window
    /// still needs *something* to report — see ``reportPendingJWTIfNeeded()``.
    private struct PendingJWTAfterSignIn: Error {}

    /// Whether `state` is the issue-#53 "session established, JWT pending"
    /// window. Doesn't need its own case-exhaustiveness guard the way
    /// `shouldReport(_:)` does — `AuthService.State` isn't a package-level
    /// total-switch surface this PR's privacy contract governs, and this
    /// predicate only ever asks one specific question of it.
    nonisolated static func isPendingJWTWindow(_ state: AuthService.State) -> Bool {
        if case .signedIn(payload: nil) = state { return true }
        return false
    }

    /// Report a pending-JWT window left by the sign-in leg that just settled.
    ///
    /// Issue #106 review Fix 6: the PR's own capture-site table lists
    /// `.serverFailure` as a reported sign-in outcome, but a `.serverFailure`
    /// on the JWT leg specifically doesn't reach `lastError` at all — leg 2
    /// of `completeSignIn(establishing:)` deliberately treats a transient
    /// failure there as "keep the session, enter the pending window," not an
    /// error (see `AuthError.offline(message:)`'s neighbor doc comment on
    /// that method). Without this, that outcome was reported nowhere,
    /// silently contradicting the PR's own claim.
    ///
    /// Needs no package change: `.signedIn(payload: nil)` is already public
    /// and already documented as meaning exactly this, so observing
    /// `auth.state` after `submit()`/`submitCode()` settle is sufficient.
    /// The specific status (503 vs. a transport failure) is lost — `AuthService`
    /// doesn't preserve it past the pending-window transition either — but
    /// "sign-in completed with the JWT leg unresolved" is the signal actually
    /// worth having, and it costs no new seam in `WXYCAPI`.
    ///
    /// Only `submit()`/`submitCode()` call this: `requestCode()`/`resendCode()`
    /// never touch `state` (no session exists yet at that point), so checking
    /// it there would risk reporting a stale pending window left by an
    /// unrelated, earlier sign-in rather than this call's own outcome.
    private func reportPendingJWTIfNeeded() {
        guard Self.isPendingJWTWindow(auth.state) else { return }
        reporter.report(PendingJWTAfterSignIn(), context: "LoginViewModel.pendingJWT")
    }

    // MARK: - Analytics (issue #108)

    /// Records `sign_in_completed`/`sign_in_failed` for the leg that just
    /// settled. Called from `submit()`/`submitCode()` only — `requestCode()`
    /// and `resendCode()` send a mailed code, they don't sign anyone in, so
    /// they have no `sign_in_*` outcome to report (matching why they're
    /// excluded from ``AuthService/State/isSignedIn`` transitions entirely).
    ///
    /// Reads `auth.lastError`/`auth.isSignedIn` post-hoc, the same pattern
    /// ``reportIfDefect()`` uses and for the same reason: `AuthService`
    /// clears `lastError` at the start of `signIn`, so whatever is here once
    /// the `await` returns is this call's own outcome. `isSignedIn` is `true`
    /// for **both** `.signedIn(payload:)` cases, including the issue-#53
    /// pending-JWT window (`payload: nil`) — the DJ genuinely is signed in
    /// there, which is a different, narrower fact than
    /// ``reportPendingJWTIfNeeded()``'s "was the JWT leg itself clean,"
    /// worth recording to Sentry separately but not worth splitting this
    /// product event over.
    private func recordSignInOutcome(method: SignInMethod) {
        if let error = auth.lastError {
            analytics.capture(SignInFailedEvent(method: method, reason: SignInFailureReason(error)))
        } else if auth.isSignedIn {
            analytics.capture(SignInCompletedEvent(method: method))
        }
    }

    /// Everything a completed sign-in leg has to do once `auth` has settled,
    /// in the one order that is correct. Both legs (`submit`, `submitCode`)
    /// end with a single call to this, so a future third credential route
    /// can't wire up two of the three and silently drop the other -- which is
    /// exactly the shape of the gap `reportPendingJWTIfNeeded()` was added to
    /// close in the first place.
    ///
    /// All three read `auth`'s state post-hoc rather than taking a returned
    /// outcome, because `AuthService.signIn` records into `lastError` instead
    /// of throwing (issue #100's contract) -- see ``reportIfDefect()``.
    private func settle(method: SignInMethod) {
        reportIfDefect()
        reportPendingJWTIfNeeded()
        recordSignInOutcome(method: method)
    }

    // MARK: - Actions

    /// Ask for a code and advance to the entry step. Stays on `.identifier` if
    /// anything fails, with the reason in ``displayedError``.
    func requestCode() async {
        guard canRequestCode else { return }
        isSendingCode = true
        defer { isSendingCode = false }
        // Unconditional, so a branch added later cannot forget it — and on
        // failure as much as success, since the failure most worth throttling is
        // the one saying we are already over the limit. Leaving the button live
        // after a 429 invites the DJ to spend the rest of a shared per-IP budget
        // on requests that cannot succeed. `AuthService` has already recorded the
        // reason in `lastError`.
        defer { startResendCooldown() }

        let destination = try? await auth.sendLoginCode(identifier: trimmedIdentifier)
        reportIfDefect()
        guard let destination else { return }
        code = ""
        stage = .awaitingCode(destination)
    }

    /// Mail another code to the address already resolved, subject to the cooldown.
    ///
    /// Goes through `resendLoginCode(to:)` rather than re-running `requestCode()`:
    /// a username would otherwise re-POST the lookup for an answer that cannot
    /// have changed — the identifier field isn't even on screen by then — spending
    /// two slots of a shared per-IP budget where one would do, in exactly the
    /// moment (slow mail, expired code) a DJ taps most.
    ///
    /// `try?` swallows the throw here (there is no caller left to react to it),
    /// but `reportIfDefect()` still fires — a resend that lands a
    /// ``AuthError/serverFailure(status:message:)`` in `auth.lastError` would
    /// otherwise be a defect that is silently swallowed rather than merely
    /// silently *un-thrown*.
    func resendCode() async {
        guard canResendCode, case let .awaitingCode(destination) = stage else { return }
        isSendingCode = true
        defer { isSendingCode = false }
        defer { startResendCooldown() }

        try? await auth.resendLoginCode(to: destination.email)
        reportIfDefect()
    }

    /// Close the resend window, and schedule the reopen that re-renders the view.
    private func startResendCooldown() {
        cooldownTask?.cancel()
        isResendOnCooldown = true
        // `weak self` so a dismissed login screen isn't pinned in memory for the
        // length of the window by a task whose only job is to flip one flag.
        cooldownTask = Task { [weak self, sleep] in
            try? await sleep(Self.defaultResendCooldown)
            guard !Task.isCancelled else { return }
            self?.isResendOnCooldown = false
        }
    }

    /// Redeem the typed code. Lands in exactly the state a password sign-in
    /// lands in — same session, same JWT exchange, same state machine.
    func submitCode() async {
        guard canSubmitCode, case let .awaitingCode(destination) = stage else { return }
        await auth.signIn(email: destination.email, otp: code)
        settle(method: .otp)
    }

    func submit() async {
        guard canSubmit else { return }
        // Trim whitespace on the identifier only — keyboards (and password
        // managers) routinely emit a trailing space on autofill and the server
        // would 401. Password intentionally untrimmed; whitespace in a password
        // is significant.
        await auth.signIn(identifier: trimmedIdentifier, password: password)
        settle(method: .password)
    }

    // MARK: - Stage changes

    /// Every stage change clears **both** error surfaces.
    ///
    /// `auth.lastError` is otherwise cleared only when a sign-in starts or a
    /// sign-out completes, so a failed code verify would still be set when the
    /// DJ switches to the password form — showing OTP copy under a form that
    /// never produced it. `clearLastError()` exists for this.
    private func enter(_ next: Stage) {
        auth.clearLastError()
        stage = next
        // The cooldown deliberately survives a stage change — see canRequestCode.
    }

    func usePassword() {
        enter(.password)
    }

    func useCode() {
        enter(.identifier)
    }

    /// Back out of the code step to correct a mistyped identifier — the only
    /// recourse when the DJ typo'd an *email*, since the server cannot report
    /// that (an unknown address still answers "code sent").
    func changeIdentifier() {
        code = ""
        enter(.identifier)
    }
}
