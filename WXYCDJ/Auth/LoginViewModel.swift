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
    /// genuinely exclusive and two of them carry data — and because the stage is
    /// what keeps the screen's two error surfaces from ever appearing together
    /// (see ``sendError``).
    enum Stage: Equatable {
        /// The default. One field; the DJ asks for a code.
        case identifier
        /// A code is in the DJ's inbox. `email` keys the verify call;
        /// `displayTarget` is the only one of the two safe to render — it is
        /// "your registered email" whenever the address was resolved from a
        /// username rather than typed.
        case awaitingCode(email: String, displayTarget: String)
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

    /// A failure from requesting a code, which has nowhere else to render.
    ///
    /// `sendLoginCode` never sets `auth.lastError` (it drives no state), so
    /// without this a lookup failure or a rate limit would be silent. The two
    /// surfaces cannot collide because each belongs to a different stage:
    /// `sendError` to `.identifier`, `auth.lastError` to `.awaitingCode` and
    /// `.password`.
    private(set) var sendError: String?

    /// When the last code was mailed, for the resend cooldown. Monotonic rather
    /// than wall-clock: this measures an elapsed interval, and a backward clock
    /// correction would otherwise park the anchor in the future and disable
    /// resend until real time caught up. Same reasoning as `ConnectivityMonitor`'s
    /// probe cooldown.
    private var codeSentAt: ContinuousClock.Instant?

    private let auth: AuthService
    private let now: @Sendable () -> ContinuousClock.Instant
    private let resendCooldown: Duration

    /// better-auth allows 3 requests per 60s on the send route, so 30 s leaves
    /// headroom (2/min) while still letting a DJ whose mail is slow try again
    /// without feeling stuck.
    static let defaultResendCooldown: Duration = .seconds(30)

    init(
        auth: AuthService,
        resendCooldown: Duration = LoginViewModel.defaultResendCooldown,
        now: @escaping @Sendable () -> ContinuousClock.Instant = { ContinuousClock.now }
    ) {
        self.auth = auth
        self.resendCooldown = resendCooldown
        self.now = now
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
    var canRequestCode: Bool {
        !trimmedIdentifier.isEmpty && !isSendingCode
    }

    var canSubmit: Bool {
        !trimmedIdentifier.isEmpty && !password.isEmpty && auth.state != .signingIn
    }

    var canSubmitCode: Bool {
        code.count == 6 && auth.state != .signingIn
    }

    /// Whether a fresh code may be requested yet. `nil` anchor means none has
    /// been sent in this session, so resend is open.
    var canResendCode: Bool {
        guard !isSendingCode else { return false }
        guard let codeSentAt else { return true }
        return now() - codeSentAt >= resendCooldown
    }

    // MARK: - Actions

    /// Ask for a code and advance to the entry step. Stays on `.identifier` if
    /// anything fails, with the reason in ``sendError``.
    func requestCode() async {
        guard canRequestCode else { return }
        isSendingCode = true
        sendError = nil
        defer { isSendingCode = false }

        do {
            let destination = try await auth.sendLoginCode(identifier: trimmedIdentifier)
            codeSentAt = now()
            code = ""
            stage = .awaitingCode(email: destination.email, displayTarget: destination.displayTarget)
        } catch let error as AuthError {
            sendError = error.localizedMessage
        } catch {
            sendError = AuthError.network(message: error.localizedDescription).localizedMessage
        }
    }

    /// Mail another code for the same identifier, subject to the cooldown.
    func resendCode() async {
        guard canResendCode else { return }
        await requestCode()
    }

    /// Redeem the typed code. Lands in exactly the state a password sign-in
    /// lands in — same session, same JWT exchange, same state machine.
    func submitCode() async {
        guard canSubmitCode, case let .awaitingCode(email, _) = stage else { return }
        await auth.signIn(email: email, otp: code)
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
        sendError = nil
        auth.clearLastError()
        stage = next
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
