//
//  AuthService.swift
//  WXYCAPI
//
//  Owns the better-auth session lifecycle for a single signed-in DJ: takes an
//  identifier + password, calls whichever sign-in route the identifier belongs
//  to (`SignInIdentifier` picks /auth/sign-in/email or /auth/sign-in/username,
//  issue #97) with the bearer plugin's `set-auth-token` header capture,
//  exchanges the session for a short-lived JWT via /auth/token, and refreshes
//  the JWT before it expires. All state is gated to the MainActor so SwiftUI
//  views can observe directly.
//
//  Created by Jake on 5/14/26.
//  Copyright © 2026 WXYC. All rights reserved.
//

import Foundation
import Observation

public enum AuthError: Error, Sendable, Equatable {
    case invalidCredentials
    case network(message: String)
    case missingSessionToken
    case serverFailure(status: Int, message: String?)
    /// The server understood the request and refused it for a stated reason the
    /// DJ can act on — a malformed email (`400 INVALID_EMAIL`), an unverified
    /// address (`403 EMAIL_NOT_VERIFIED`, since Backend-Service sets
    /// `requireEmailVerification: true`). Distinct from ``invalidCredentials``,
    /// which asserts the username/password pair was wrong: folding these into it
    /// would have a DJ retyping a correct password against a problem retyping
    /// can't fix. Distinct from ``serverFailure`` too, because that renders
    /// behind a "Server error (4xx)" prefix, reading as a backend fault for
    /// something the DJ mistyped.
    case rejected(message: String?)
    /// The server refused because too many requests arrived too quickly, not
    /// because anything about the credential was wrong.
    ///
    /// Distinct from ``serverFailure``, which it used to fall through to and
    /// render as "Server error (429)": a rate limit is neither a fault nor
    /// permanent, and the recovery is to wait — something the DJ can only do if
    /// told. Reachable in ordinary use rather than as an abuse signal, because
    /// Backend-Service keys its limiter on `X-Real-IP` (10 per 15 min) and the
    /// control room shares one egress address, while an OTP sign-in spends three
    /// requests of that bucket to a password's one.
    ///
    /// Payload-free deliberately: neither limiter returns a `Retry-After` this
    /// app reads, so there is nothing to carry, and `AuthError` is compared with
    /// `==` throughout the tests.
    case rateLimited
    case notSignedIn

    public var localizedMessage: String {
        switch self {
        case .invalidCredentials: "Incorrect username or email, or password."
        case .network(let m): "Network error: \(m)"
        case .missingSessionToken: "Sign-in did not return a session token."
        case .serverFailure(let s, let m): "Server error (\(s))\(m.map { ": \($0)" } ?? "")."
        // Empty-guarded rather than a bare `map`, so a `{"message": ""}` body
        // renders the fallback instead of a lone ".". No period-doubling guard:
        // better-auth's messages arrive unpunctuated, so it would be dead code.
        case .rejected(let m): m.flatMap { $0.isEmpty ? nil : "\($0)." } ?? "Sign-in was rejected."
        case .rateLimited: "Too many attempts. Wait a few minutes and try again."
        case .notSignedIn: "You are signed out."
        }
    }
}

@MainActor
@Observable
public final class AuthService {
    public enum State: Sendable, Equatable {
        case unknown
        case signedOut
        case signingIn
        /// An authenticated DJ. The associated payload is the decoded JWT when
        /// one is in hand, or `nil` for "session established, JWT pending" — a
        /// real session token was issued but the `/auth/token` exchange failed
        /// transiently (issue #53). The session token is the credential; the
        /// JWT is a derived, re-mintable artifact, so a pending window is still
        /// signed in. Nothing reads the payload off `state` (every consumer keys
        /// on the case via `isSignedIn`), so `nil` is a benign sentinel and the
        /// JWT is obtained lazily on first use by `currentJWT()`.
        case signedIn(payload: JWTPayload?)

        /// Whether this state represents an authenticated DJ. Lets the deep-link
        /// auth-change handler (issue #19 step 7) compare a transition's old vs.
        /// new value — distinguishing a genuine sign-out (`.signedIn` → not) from
        /// a cold-launch `.unknown` → `.signedOut` that must keep a parked tap.
        public var isSignedIn: Bool {
            if case .signedIn = self { return true }
            return false
        }
    }

    public private(set) var state: State = .unknown
    public private(set) var lastError: AuthError?

    /// Whether a DJ is currently signed in. The Spotlight deep-link handler
    /// (issue #19 step 7) reads this to decide whether to present a tapped
    /// album immediately or stash it for replay once `restoreSession()` (or a
    /// fresh sign-in) resolves `state` to `.signedIn`.
    public var isSignedIn: Bool { state.isSignedIn }

    private let configuration: WXYCAPIConfiguration
    private let storage: any TokenStorage
    /// Deliberately typed as the decorator, not `any RequestSession`: it makes
    /// `self.session = session` fail to compile, so the no-cookie policy can't be
    /// dropped by a consumer that copies this shape (issue #99).
    private let session: CookielessSession

    /// Reports each auth-transport result to the connectivity layer (issue #71),
    /// mirroring ``APIClient``'s `onOutcome`: `true` when the server answered (any
    /// HTTP status — we reached it, even a `401`), `false` on a thrown transport
    /// error (no network / captive portal / DNS / timeout) — but **not** a
    /// cancellation, which reports nothing (see ``send(_:)``). `nil` outside the
    /// app (unit tests that don't observe connectivity).
    ///
    /// Pure observation — invoked around every `session.data(for:)` (see
    /// ``send(_:)``), which rethrows the original error untouched, so it never
    /// alters the issue-#53/#66 auth state machine; it only feeds the same signal
    /// a failed ``APIClient`` request does. `AppDependencies` supplies a closure
    /// that hops to `ConnectivityMonitor.ingest(isOnline:)` (the `nonisolated`,
    /// ordered funnel), keeping `AuthService` free of any `ConnectivityMonitor`
    /// coupling — the hook is an opaque `(Bool) -> Void`, exactly as the
    /// ``APIClient`` hook is wired.
    private let onOutcome: (@Sendable (Bool) -> Void)?

    private var sessionToken: String?
    private var cachedJWT: (token: String, payload: JWTPayload)?

    /// Monotonic session-*generation* counter. Bumped whenever the session is
    /// cleared (`clearLocalSession`) or a brand-new one is established (`signIn`),
    /// but **not** on a `set-auth-token` rotation (`captureRotatedSessionToken`),
    /// which re-issues the bearer *within* the same generation. `refreshJWT`
    /// captures it before awaiting `/auth/token` and re-checks it after, so a
    /// `signOut` (or re-sign-in) that lands during an in-flight refresh can't be
    /// resurrected by the 2xx success path re-persisting a stale rotation/JWT
    /// (issue #66). The generation framing is what keeps a benign concurrent
    /// double-refresh — where only the bearer rotated — from spuriously failing.
    private var sessionEpoch: UInt64 = 0

    private static let refreshLeeway: TimeInterval = 60

    public init(
        configuration: WXYCAPIConfiguration = .production,
        storage: any TokenStorage = KeychainTokenStorage(),
        session: any RequestSession = URLSession.shared,
        onOutcome: (@Sendable (Bool) -> Void)? = nil
    ) {
        self.configuration = configuration
        self.storage = storage
        self.session = CookielessSession(session)
        self.onOutcome = onOutcome
    }

    public func restoreSession() async {
        guard state == .unknown else { return }
        let stored: String?
        do {
            stored = try storage.load(.sessionToken)
        } catch {
            // Couldn't even read the Keychain — treat as no usable session.
            state = .signedOut
            return
        }
        guard let token = stored else {
            state = .signedOut
            return
        }
        sessionToken = token
        do {
            let payload = try await refreshJWT()
            state = .signedIn(payload: payload)
        } catch AuthError.notSignedIn {
            // Terminal: the stored session bearer was rejected (401). The token
            // is dead — clear it so it doesn't linger and 401 on every launch.
            clearLocalSession()
            state = .signedOut
        } catch {
            // Transient (5xx / network / undecodable body): the session may
            // still be good, but we couldn't confirm it. Consult the offline
            // grace policy (issue #57). On `.signedIn` — a within-window anchor
            // and a cached payload — restore the cached identity so a returning
            // DJ lands in the app (browsing the on-device catalog clone) instead
            // of a LoginView they may not be able to complete offline; for that
            // branch `currentJWT()` re-mints the JWT lazily once the network
            // recovers, *keeping* the already-signed-in state. On `.signedOut`
            // — anchors absent (a legacy install, or a sign-in that only ever
            // reached the pending window) or the window elapsed — fall through to
            // the login screen; note this branch is NOT self-healing mid-session
            // (a later `currentJWT()` success does not promote `.signedOut` ->
            // `.signedIn`), so recovery is on the next relaunch (the now-online
            // restore succeeds) or a manual sign-in. Either way a network failure
            // never clears tokens here: the next online launch's restore can
            // still recover the session (success) or terminally clear it (401).
            let decision = OfflineSessionPolicy.decide(
                hasStoredSession: sessionToken != nil,
                cachedPayload: loadPersistedPayload(),
                lastValidatedAt: loadLastValidatedAt(),
                now: Date()
            )
            switch decision {
            case .signedIn(let payload):
                state = .signedIn(payload: payload)
            case .signedOut:
                state = .signedOut
            }
        }
    }

    /// Sign a DJ in with the credentials they use on dj.wxyc.org.
    ///
    /// - Parameters:
    ///   - identifier: A username **or** an email address, as the one login
    ///     field accepts — ``SignInIdentifier`` routes it to the better-auth
    ///     endpoint that can accept it (issue #97). Expected pre-trimmed.
    ///   - password: Passed through verbatim; whitespace is significant.
    public func signIn(identifier: String, password: String) async {
        await completeSignIn {
            try await self.performSignIn(identifier: identifier, password: password)
        }
    }

    /// The credential-agnostic half of signing in: everything from `.signingIn`
    /// through to a settled `.signedIn` / `.signedOut`, parameterized only by how
    /// leg 1 obtains a session token.
    ///
    /// Every credential route shares this, and that sharing is the point rather
    /// than a convenience. The invariants below are subtle, individually
    /// load-bearing, and each was added to close a specific defect — the issue-#57
    /// grace-anchor reset, the issue-#66 generation bump, the issue-#53
    /// transient/terminal split, issue-#52's leave-no-trace rollback. A second
    /// route that restated them would be free to restate one of them *wrongly*,
    /// and the resulting drift would be invisible until the exact interleaving
    /// that defect covers came back. So a new credential supplies a closure that
    /// yields a session token, and inherits all of it.
    ///
    /// - Parameter establishing: Leg 1. Returns the session token on success;
    ///   any throw is terminal for the sign-in.
    private func completeSignIn(establishing: () async throws -> String) async {
        state = .signingIn
        lastError = nil

        // Issue #57: drop any prior DJ's grace anchors before establishing a new
        // session. They belong to the *previous* identity; if this sign-in's JWT
        // leg fails transiently (leg 2 below), it enters the pending window
        // WITHOUT persisting fresh anchors, so a stale `.payload` left here would
        // later let an offline restore pair this session's bearer with the old
        // DJ's cached identity. A successful refreshJWT re-persists both anchors.
        clearGraceAnchors()

        // Leg 1 — establish the session. Any failure here is terminal: there is
        // no session to keep, so roll back and stop before the JWT exchange.
        let token: String
        do {
            token = try await establishing()
            try storage.save(token, for: .sessionToken)
            sessionToken = token
            sessionEpoch &+= 1  // a new generation, so a stale refresh of any prior session can't clobber it (issue #66)
        } catch let error as AuthError {
            clearLocalSession()
            lastError = error
            state = .signedOut
            return
        } catch {
            clearLocalSession()
            lastError = .network(message: error.localizedDescription)
            state = .signedOut
            return
        }

        // Leg 2 — exchange the session for a JWT. A transient failure here is
        // NOT terminal: the session is real, so we keep it and obtain the JWT
        // lazily on first use (issue #53). Only a 401 (session bearer rejected)
        // is terminal and rolls back, preserving #52's leave-no-trace contract.
        do {
            let payload = try await refreshJWT()
            state = .signedIn(payload: payload)
        } catch AuthError.notSignedIn {
            clearLocalSession()
            lastError = .notSignedIn
            state = .signedOut
        } catch {
            // Transient: keep the session token (incl. any value rotated and
            // persisted by `refreshJWT`) and enter the pending window. `lastError`
            // was already cleared at the top of `signIn`, so pending carries no
            // error — same as `restoreSession`'s transient arm.
            state = .signedIn(payload: nil)
        }
    }

    /// Mail a one-time sign-in code to the DJ behind `identifier` (issue #100).
    ///
    /// Two legs, the first often skipped. `POST /auth/wxyc/lookup-email` resolves
    /// a username to the address the code goes to; an identifier containing `@`
    /// skips it entirely, because the resolver's own first line echoes such an
    /// identifier back unchanged (`if (identifier.includes('@')) return identifier;`).
    /// Then `POST /auth/email-otp/send-verification-otp` mails a 6-digit code
    /// valid for five minutes.
    ///
    /// Deliberately does **not** touch ``state``. No session exists yet, so
    /// entering `.signingIn` would claim one is being established and strand the
    /// UI in a spinner state on failure; the view model owns the in-flight and
    /// error surface for this step instead. `lastError` is cleared on entry, the
    /// way ``signIn(identifier:password:)`` clears it, so a stale message from an
    /// earlier attempt can't sit under a fresh one.
    ///
    /// It also **records the failure in ``lastError``** before rethrowing, so
    /// every credential route reports errors the same way. `signIn` reports by
    /// mutating `lastError`; having this one report only by throwing forced the
    /// UI to keep a second error store and coalesce the two, which is a hazard
    /// that already produced one defect (a resend failure that both went
    /// unrendered *and* erased the message on screen, since this method clears
    /// `lastError` on entry). One convention, one surface, one thing for the next
    /// credential route to copy.
    ///
    /// - Returns: The address the code went to, plus how much of it may be shown
    ///   — see ``LoginCodeDestination``.
    /// - Throws: ``AuthError/rejected(message:)`` when no account matches;
    ///   ``AuthError/rateLimited`` on a 429 from either leg.
    public func sendLoginCode(identifier: String) async throws -> LoginCodeDestination {
        lastError = nil
        return try await recordingFailure {
            let classified = SignInIdentifier(identifier)

            let email: String
            switch classified {
            case .email(let typed):
                email = typed
            case .username:
                email = try await self.lookUpEmail(identifier: identifier)
            }

            try await self.sendVerificationCode(to: email)
            return LoginCodeDestination(email: email, typedEmail: classified.typedEmail)
        }
    }

    /// Mail another code to an address ``sendLoginCode(identifier:)`` already
    /// resolved.
    ///
    /// Skips the lookup by construction, which is the point. Routing a resend
    /// back through `sendLoginCode` would re-POST `/auth/wxyc/lookup-email` for a
    /// username — an answer that cannot have changed, since the identifier field
    /// isn't even on screen by then — and spend **two** slots of Backend-Service's
    /// per-IP bucket where one would do, in precisely the situation (slow mail, an
    /// expired code) where the DJ is most likely to tap again. It also keeps the
    /// resolved address off the return path entirely, so a resend has nothing to
    /// re-derive a display string from and cannot leak one.
    public func resendLoginCode(to email: String) async throws {
        lastError = nil
        try await recordingFailure {
            try await self.sendVerificationCode(to: email)
        }
    }

    /// Run `work`, recording any failure in ``lastError`` before rethrowing.
    ///
    /// The non-session legs still `throw` — their caller is right there and can
    /// react — but they report through the same field `signIn` does, so the UI
    /// reads exactly one error surface. The `AuthError`-else-`.network` mapping
    /// mirrors `completeSignIn`'s leg 1.
    private func recordingFailure<T>(_ work: () async throws -> T) async throws -> T {
        do {
            return try await work()
        } catch {
            lastError = (error as? AuthError) ?? .network(message: error.localizedDescription)
            throw error
        }
    }

    /// Resolve a username to its verification address.
    ///
    /// Backend-Service's own route, so it answers `{error: …}` rather than
    /// better-auth's `{message, code}` — and `APIErrorResponse` requires
    /// `message`, so that body decodes to nothing at all. Failures are therefore
    /// mapped by **status**; reaching for a body message here would always yield
    /// `nil` and render `.rejected`'s bare "Sign-in was rejected." fallback.
    private func lookUpEmail(identifier: String) async throws -> String {
        let (data, http) = try await postJSON(
            path: "wxyc/lookup-email",
            body: try JSONCoders.encoder.encode(LookupEmailRequest(identifier: identifier))
        )
        switch http.statusCode {
        case 200..<300:
            guard let email = (try? JSONCoders.decoder.decode(LookupEmailResponse.self, from: data))?.email,
                  !email.isEmpty
            else {
                // `{"email": null}` — the one failure this flow can name exactly.
                // Says "username" and not "username or email" because an
                // identifier holding an `@` never reaches this leg.
                throw AuthError.rejected(message: "No account matches that username")
            }
            return email
        case 429:
            throw AuthError.rateLimited
        default:
            // Includes the route's only 400 (`identifier required`), which this
            // client cannot provoke — `LoginViewModel.canSubmit` gates the empty
            // identifier — so if it ever fires it signals a client bug, and
            // "Server error (400)" is the honest way to say that.
            throw AuthError.serverFailure(status: http.statusCode, message: nil)
        }
    }

    /// Ask better-auth to mail a code to `email`.
    ///
    /// A better-auth route, so unlike the lookup it *does* carry a readable
    /// `{message, code}`, and its 400 must render that message: `dj@wxyc`
    /// classifies as an email on the `@`, skips the lookup, and reaches
    /// `z.email()` here, which names the actual mistake. Hiding that behind
    /// "Server error (400)" would discard the exact payoff ``SignInIdentifier``
    /// routes on `@` to obtain.
    ///
    /// A 200 says nothing about whether the account exists: `disableSignUp: true`
    /// makes the server answer `{success: true}` for an unknown address after
    /// quietly discarding the code. That is deliberate anti-enumeration, and it
    /// is why a mistyped *email* cannot be reported here.
    private func sendVerificationCode(to email: String) async throws {
        let (data, http) = try await postJSON(
            path: "email-otp/send-verification-otp",
            body: try JSONCoders.encoder.encode(SendLoginCodeRequest(email: email))
        )
        switch http.statusCode {
        case 200..<300:
            return
        case 429:
            throw AuthError.rateLimited
        case 400, 403:
            throw AuthError.rejected(message: Self.serverMessage(in: data))
        default:
            throw AuthError.serverFailure(status: http.statusCode, message: Self.serverMessage(in: data))
        }
    }

    /// Sign a DJ in with a code mailed by ``sendLoginCode(identifier:)``.
    ///
    /// `POST /auth/sign-in/email-otp` is a peer of the two password routes —
    /// same `setSessionCookie`, same global `bearer()` plugin, so the same
    /// `set-auth-token` header — which is why this is a one-line call rather
    /// than a second state machine. Everything after the token is obtained is
    /// shared with the password path by construction.
    ///
    /// One server-side asymmetry worth knowing, since it is invisible from here:
    /// Backend-Service sets `requireEmailVerification: true`, so an unverified
    /// account is refused at password sign-in — but this route instead *marks it
    /// verified* and proceeds, on the reasoning that possession of the mailbox is
    /// the very proof the verification email would have demanded. See ADR 0006.
    ///
    /// - Parameters:
    ///   - email: ``LoginCodeDestination/email``, not the typed identifier.
    ///   - otp: The DJ's typed code; normalized to digits before it is sent.
    public func signIn(email: String, otp: String) async {
        await completeSignIn {
            // The server's alphabet is provably `0-9` — better-auth's
            // `defaultOTPGenerator` is `generateRandomString(otpLength ?? 6, "0-9")`
            // and Backend-Service overrides `otpLength` but not `generateOTP` — so
            // discarding non-digits can only ever drop characters a real code
            // cannot contain, and it makes a code pasted as "123 456" work. The UI
            // strips at input too; this is the guard for every other caller of
            // what is, after all, public API.
            let digits = otp.filter(\.isNumber)
            return try await self.establishSession(
                path: "sign-in/email-otp",
                body: try JSONCoders.encoder.encode(OTPSignInRequest(email: email, otp: digits)),
                rejectionCopy: OTPRejection.copy(for:fallback:)
            )
        }
    }

    /// Drop the last sign-in error without touching the session.
    ///
    /// `lastError` is otherwise cleared only when a sign-in begins or a sign-out
    /// completes, which leaves a login screen with more than one credential form
    /// able to show a message the visible form never produced — a failed code
    /// verify still set when the DJ switches to the password field. The UI clears
    /// it on every such transition.
    public func clearLastError() {
        lastError = nil
    }

    /// POST a JSON body to an auth-service path and hand back the raw response.
    ///
    /// Shares ``send(_:)`` — and therefore the issue-#71 connectivity hook, and
    /// the ``CookielessSession`` that `send` issues over (issue #99) — with every
    /// other request this service makes. That sharing is the point: both OTP legs
    /// are non-GET better-auth
    /// routes, so both sit under the global `originCheckMiddleware` that a
    /// lingering cookie arms, and a hand-rolled `URLRequest` here would silently
    /// opt out of the fix `b5ea02d` landed.
    private func postJSON(path: String, body: Data) async throws -> (Data, HTTPURLResponse) {
        let url = configuration.authBaseURL.appending(path: path)
        var request = URLRequest(url: url, timeoutInterval: configuration.timeout)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.httpBody = body

        let (data, response) = try await send(request)
        guard let http = response as? HTTPURLResponse else {
            throw AuthError.network(message: "Non-HTTP response")
        }
        return (data, http)
    }

    /// Forget every local trace of the session: the in-memory bearer, the cached
    /// JWT, and everything in storage. Used by three terminal paths that must
    /// leave nothing behind:
    ///
    /// - A failed `signIn`: the session token is persisted (and may be
    ///   re-persisted on rotation by `refreshJWT`) *before* the JWT exchange is
    ///   confirmed, so an interrupted handshake can orphan a token in the
    ///   Keychain. Since we report the sign-in as failed, it must leave no
    ///   trace; otherwise the next cold launch's `restoreSession()` finds the
    ///   token, completes the exchange, and silently skips the login screen.
    /// - `restoreSession`'s 401 arm: a revoked stored token would otherwise
    ///   linger and 401 on every launch.
    /// - `currentJWT`'s lazy-demotion arm: a session that dies while the app is
    ///   open must self-heal to the login screen rather than strand the DJ.
    ///
    /// Unlike `restoreSession`'s *transient* arm — which keeps a previously-good
    /// token so an offline blip can retry — these three have proven there is
    /// nothing worth keeping.
    private func clearLocalSession() {
        sessionToken = nil
        cachedJWT = nil
        sessionEpoch &+= 1  // a new generation: invalidate any in-flight refresh (issue #66)
        try? storage.clearAll()
    }

    public func signOut() async {
        if let token = sessionToken {
            _ = try? await callSignOut(sessionToken: token)
        }
        clearLocalSession()
        state = .signedOut
        lastError = nil
    }

    public func currentJWT() async throws -> String {
        if let cached = cachedJWT, cached.payload.expiration.timeIntervalSinceNow > Self.refreshLeeway {
            return cached.token
        }
        guard let tokenAtRefresh = sessionToken else { throw AuthError.notSignedIn }
        do {
            _ = try await refreshJWT()
        } catch AuthError.notSignedIn {
            // The session bearer was rejected (401): the session is dead. Demote
            // to signed-out so `RootView` swaps `MainView` → `LoginView`, rather
            // than stranding the DJ in a `MainView` whose every authed call
            // 401s. This is the way back out of the issue-#53 pending window —
            // and it also closes a pre-existing gap, where a session revoked
            // mid-use left `state` pinned at `.signedIn` with no path back short
            // of force-quit. `APIClient`'s one-shot 401 retry funnels here too.
            //
            // Demote only if the rejected bearer is *still* the current session.
            // This is the shared lazy-refresh chokepoint for every authed caller
            // — interactive search/bin AND the background catalog refresh, which
            // share one `AuthService` — so two refreshes can overlap, each having
            // bound its bearer before suspending. If a concurrent re-sign-in (or
            // a rotation captured by the other in-flight refresh) replaced
            // `sessionToken` while we awaited, this 401 is for a superseded
            // bearer: clobbering would erase a valid new session and spuriously
            // bounce the DJ to login. Report this stale attempt as
            // unauthenticated instead and let the caller retry the live session.
            if sessionToken == tokenAtRefresh {
                clearLocalSession()
                lastError = .notSignedIn
                state = .signedOut
            }
            throw AuthError.notSignedIn
        }
        // A transient throw above propagates unchanged: `state` stays `.signedIn`
        // and the calling view shows its normal retryable error. On success we
        // leave `state` untouched — the payload is never read off `state`, so
        // promoting `.signedIn(nil)` → `.signedIn(payload)` has no consumer and
        // would only reintroduce `onChange` churn on every ~hourly refresh.
        guard let token = cachedJWT?.token else { throw AuthError.notSignedIn }
        return token
    }

    public func invalidateJWT() {
        cachedJWT = nil
        try? storage.clear(.jwt)
    }

    /// Perform an auth-transport request, reporting the connectivity outcome
    /// (issue #71) before returning or rethrowing. A completed exchange — any HTTP
    /// status, even a `401` — proves the server was reachable (`true`); a thrown
    /// transport error means we never reached it (`false`). A **cancellation** is
    /// neither — it's a deliberate abandonment (the search debounce / background-
    /// refresh expiration cancel a JWT-refresh leg in flight), so it reports
    /// nothing and just rethrows, leaving the connectivity state untouched.
    /// Mirrors ``APIClient/fire(_:)``'s cancellation handling, but **rethrows the
    /// original error untouched** (no `AuthError`/`APIError.network` wrapping), so
    /// every caller's existing error handling — and the issue-#53/#66 state
    /// machine — is byte-for-byte unchanged. Pure observation: the only added
    /// effect is the `onOutcome` call.
    private func send(_ request: URLRequest) async throws -> (Data, URLResponse) {
        do {
            let result = try await session.data(for: request)
            onOutcome?(true)
            return result
        } catch {
            // A cancelled request says nothing about connectivity — the caller
            // superseded the call (the issue-#58 search debounce cancels the
            // in-flight task on every keystroke; the background-refresh expiration
            // handler cancels its work), it didn't fail to reach the server — so
            // don't latch the monitor. Covers both forms a cancelled `data(for:)`
            // takes: URLSession's `URLError.cancelled` and a `CancellationError` a
            // `RequestSession` may surface. Any other error is a real transport
            // failure → offline. The original error always rethrows untouched, so
            // the issue-#53/#66 state machine is unchanged.
            let isCancellation = (error as? URLError)?.code == .cancelled || error is CancellationError
            if !isCancellation { onOutcome?(false) }
            throw error
        }
    }

    private func performSignIn(identifier rawIdentifier: String, password: String) async throws -> String {
        // One field, two better-auth routes: an email posted to the username
        // route is rejected on shape alone (422 "Username is invalid") before
        // any credential check, so the identifier decides both the path and the
        // body key. Everything after this — the `set-auth-token` capture, the
        // JWT exchange, the issue-#53/#66 state machine — is route-agnostic.
        let identifier = SignInIdentifier(rawIdentifier)
        return try await establishSession(
            path: identifier.path,
            body: try identifier.encodedBody(password: password)
        )
    }

    /// POST a credential body to a better-auth sign-in route and return the
    /// session token it issues.
    ///
    /// The counterpart to ``completeSignIn(establishing:)``: that owns the state
    /// machine, this owns the wire. Every sign-in route reaches the same
    /// response shape — `bearer()` is a global plugin, so `set-auth-token`
    /// arrives identically — and the same refusal vocabulary, so both live here
    /// once instead of once per credential.
    ///
    /// - Parameter rejectionCopy: How to word a 400/403 refusal, given the
    ///   server's `code` and `message`. Defaults to rendering the server's own
    ///   message, which is what the password routes want; a route whose codes
    ///   have friendlier equivalents (the OTP codes, issue #100) supplies its
    ///   own. **Status classification stays here** — only the string varies, so
    ///   a route cannot accidentally reclassify a 401 as recoverable.
    private func establishSession(
        path: String,
        body: Data,
        rejectionCopy: (_ code: String?, _ message: String?) -> String? = { _, message in message }
    ) async throws -> String {
        let (data, http) = try await postJSON(path: path, body: body)
        switch http.statusCode {
        case 200..<300:
            if let token = http.value(forHTTPHeaderField: "set-auth-token"), !token.isEmpty {
                return token
            }
            if let bodyToken = try? JSONCoders.decoder.decode([String: String].self, from: data)["token"], !bodyToken.isEmpty {
                return bodyToken
            }
            throw AuthError.missingSessionToken
        case 401:
            throw AuthError.invalidCredentials
        case 429:
            throw AuthError.rateLimited
        case 400, 403:
            // The server refused for a reason it named, and the reason is not
            // "wrong password": a malformed email, an unverified address, a
            // rejected origin, a stale one-time code. Surface its reason rather
            // than asserting a credential failure the DJ would try to fix by
            // retyping.
            let body = Self.serverError(in: data)
            throw AuthError.rejected(message: rejectionCopy(body?.code, body?.message))
        default:
            throw AuthError.serverFailure(status: http.statusCode, message: Self.serverMessage(in: data))
        }
    }

    /// The `message` out of a non-2xx body, or `nil` if it isn't shaped like one.
    /// Mirrors ``APIClient/httpError(status:body:)``'s reason for existing: keep
    /// the "what does an error body look like" decision in one place, so a second
    /// message key or a decode fallback is a single edit rather than one per arm.
    private static func serverMessage(in data: Data) -> String? {
        serverError(in: data)?.message
    }

    /// The decoded better-auth error body, or `nil` if this isn't one.
    ///
    /// The single place that decides what an error body looks like — which is
    /// what ``serverMessage(in:)``'s doc comment has always claimed, and what two
    /// independent decoders quietly stopped delivering. Decoding once also means
    /// `code` and `message` provably come from the same parse.
    ///
    /// Note this reads better-auth's `{message, code}` vocabulary. Backend-Service's
    /// own routes and the Express rate limiter answer `{error: …}`, which
    /// ``APIErrorResponse`` (required `message`) cannot decode at all — callers on
    /// those paths map by status instead of reaching for this.
    private static func serverError(in data: Data) -> APIErrorResponse? {
        try? JSONCoders.decoder.decode(APIErrorResponse.self, from: data)
    }

    private func refreshJWT() async throws -> JWTPayload {
        guard let token = sessionToken else { throw AuthError.notSignedIn }
        let epochAtRefresh = sessionEpoch
        let url = configuration.authBaseURL.appending(path: "token")
        var request = URLRequest(url: url, timeoutInterval: configuration.timeout)
        request.httpMethod = "GET"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        let (data, response) = try await send(request)
        guard let http = response as? HTTPURLResponse else {
            throw AuthError.network(message: "Non-HTTP response")
        }
        guard (200..<300).contains(http.statusCode) else {
            if http.statusCode == 401 { throw AuthError.notSignedIn }
            throw AuthError.serverFailure(status: http.statusCode, message: nil)
        }
        // Bail before persisting anything if the session was cleared or replaced
        // (signOut / re-sign-in) while we awaited (issue #66). Otherwise this 2xx
        // resurrects a torn-down session: `captureRotatedSessionToken` writes the
        // rolling-renewal bearer back to the Keychain and we cache+persist the
        // JWT — leaving `state == .signedOut` but a live token that the next cold
        // launch's `restoreSession()` silently signs back in (defeating signOut,
        // violating #52's leave-no-trace). The success-path mirror of
        // `currentJWT`'s 401-path guard. A *rotation* captured by a concurrent
        // refresh keeps the same generation, so a benign overlapping
        // double-refresh still persists for both callers.
        guard sessionEpoch == epochAtRefresh else { throw AuthError.notSignedIn }
        captureRotatedSessionToken(from: http)
        let decoded = try JSONCoders.decoder.decode(JWTResponse.self, from: data)
        let payload = try JWTDecoder.decode(decoded.token)
        cachedJWT = (decoded.token, payload)
        try? storage.save(decoded.token, for: .jwt)
        // Issue #57: a successful exchange is a confirmed server contact, so
        // reset the offline grace window and refresh the durable payload. This
        // is the single chokepoint for sign-in, cold-launch restore, and the
        // lazy refresh — every path that proves the session is live flows here.
        persistValidationAnchors(payload: payload)
        return payload
    }

    // MARK: - Offline grace anchors (issue #57)

    /// Persist the offline grace anchors: the wall-clock of this confirmed
    /// server contact and a durable copy of the payload. Best-effort — a
    /// storage failure degrades to a shorter grace, never blocks the refresh.
    private func persistValidationAnchors(payload: JWTPayload) {
        try? storage.save(String(Date().timeIntervalSince1970), for: .lastValidatedAt)
        if let json = Self.encodePayload(payload) {
            try? storage.save(json, for: .payload)
        }
    }

    /// Drop the offline grace anchors without touching the session/JWT slots.
    /// Used at `signIn` entry so a new session can't inherit the previous DJ's
    /// cached identity (the terminal paths clear these via `storage.clearAll()`).
    private func clearGraceAnchors() {
        try? storage.clear(.lastValidatedAt)
        try? storage.clear(.payload)
    }

    private func loadLastValidatedAt() -> Date? {
        guard let raw = (try? storage.load(.lastValidatedAt)) ?? nil,
              let seconds = TimeInterval(raw),
              // Reject a non-finite parse (`TimeInterval("inf")` succeeds): an
              // infinite anchor would otherwise read as in-window forever. The
              // policy guards this too, but stop it at the storage boundary.
              seconds.isFinite
        else { return nil }
        return Date(timeIntervalSince1970: seconds)
    }

    private func loadPersistedPayload() -> JWTPayload? {
        guard let json = (try? storage.load(.payload)) ?? nil,
              let data = json.data(using: .utf8),
              let payload = try? JSONCoders.decoder.decode(JWTPayload.self, from: data)
        else { return nil }
        return payload
    }

    private static func encodePayload(_ payload: JWTPayload) -> String? {
        guard let data = try? JSONCoders.encoder.encode(payload) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    /// better-auth's bearer plugin emits `set-auth-token` on every response
    /// where it re-issued the session cookie (sign-in, and rolling renewal
    /// once per `session.updateAge`). Capturing it on every auth-bearing
    /// response keeps the client in lockstep with the server's rotation
    /// schedule; missing it surfaces as a silent logout ~24h after sign-in.
    private func captureRotatedSessionToken(from response: HTTPURLResponse) {
        guard let rotated = response.value(forHTTPHeaderField: "set-auth-token"),
              !rotated.isEmpty,
              rotated != sessionToken
        else { return }
        sessionToken = rotated
        try? storage.save(rotated, for: .sessionToken)
    }

    private func callSignOut(sessionToken: String) async throws {
        let url = configuration.authBaseURL.appending(path: "sign-out")
        var request = URLRequest(url: url, timeoutInterval: configuration.timeout)
        request.httpMethod = "POST"
        request.setValue("Bearer \(sessionToken)", forHTTPHeaderField: "Authorization")
        _ = try await send(request)
    }
}
