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
        sleep: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) }
    ) {
        self.auth = auth
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
    var canResendCode: Bool {
        !isSendingCode && !isResendOnCooldown
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

        guard let destination = try? await auth.sendLoginCode(identifier: trimmedIdentifier) else { return }
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
    func resendCode() async {
        guard canResendCode, case let .awaitingCode(destination) = stage else { return }
        isSendingCode = true
        defer { isSendingCode = false }
        defer { startResendCooldown() }

        try? await auth.resendLoginCode(to: destination.email)
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
    }

    func submit() async {
        guard canSubmit else { return }
        // Trim whitespace on the identifier only — keyboards (and password
        // managers) routinely emit a trailing space on autofill and the server
        // would 401. Password intentionally untrimmed; whitespace in a password
        // is significant.
        await auth.signIn(identifier: trimmedIdentifier, password: password)
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
