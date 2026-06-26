//
//  AuthService.swift
//  WXYCAPI
//
//  Owns the better-auth session lifecycle for a single signed-in DJ: takes
//  username + password, calls /auth/sign-in/username (with the bearer
//  plugin's `set-auth-token` header capture), exchanges the session for a
//  short-lived JWT via /auth/token, and refreshes the JWT before it expires.
//  All state is gated to the MainActor so SwiftUI views can observe directly.
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
    case notSignedIn

    public var localizedMessage: String {
        switch self {
        case .invalidCredentials: "Invalid username or password."
        case .network(let m): "Network error: \(m)"
        case .missingSessionToken: "Sign-in did not return a session token."
        case .serverFailure(let s, let m): "Server error (\(s))\(m.map { ": \($0)" } ?? "")."
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
    private let session: any RequestSession

    private var sessionToken: String?
    private var cachedJWT: (token: String, payload: JWTPayload)?

    private static let refreshLeeway: TimeInterval = 60

    public init(
        configuration: WXYCAPIConfiguration = .production,
        storage: any TokenStorage = KeychainTokenStorage(),
        session: any RequestSession = URLSession.shared
    ) {
        self.configuration = configuration
        self.storage = storage
        self.session = session
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
            // grace policy (issue #57) — within the 30-day window since the last
            // confirmed server contact, restore the cached identity so a
            // returning DJ lands in the app (browsing the on-device catalog
            // clone) instead of a LoginView they may not be able to complete
            // offline; the JWT re-mints lazily once the network recovers. Past
            // the window, fall through to the login screen. A network failure
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

    public func signIn(username: String, password: String) async {
        state = .signingIn
        lastError = nil

        // Leg 1 — establish the session. Any failure here is terminal: there is
        // no session to keep, so roll back and stop before the JWT exchange.
        let token: String
        do {
            token = try await performSignIn(username: username, password: password)
            try storage.save(token, for: .sessionToken)
            sessionToken = token
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

    private func performSignIn(username: String, password: String) async throws -> String {
        let url = configuration.authBaseURL.appending(path: "sign-in/username")
        var request = URLRequest(url: url, timeoutInterval: configuration.timeout)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.httpBody = try JSONCoders.encoder.encode(SignInRequest(username: username, password: password))

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw AuthError.network(message: "Non-HTTP response")
        }
        switch http.statusCode {
        case 200..<300:
            if let token = http.value(forHTTPHeaderField: "set-auth-token"), !token.isEmpty {
                return token
            }
            if let bodyToken = try? JSONCoders.decoder.decode([String: String].self, from: data)["token"], !bodyToken.isEmpty {
                return bodyToken
            }
            throw AuthError.missingSessionToken
        case 401, 403:
            throw AuthError.invalidCredentials
        default:
            let message = (try? JSONCoders.decoder.decode(APIErrorResponse.self, from: data))?.message
            throw AuthError.serverFailure(status: http.statusCode, message: message)
        }
    }

    private func refreshJWT() async throws -> JWTPayload {
        guard let token = sessionToken else { throw AuthError.notSignedIn }
        let url = configuration.authBaseURL.appending(path: "token")
        var request = URLRequest(url: url, timeoutInterval: configuration.timeout)
        request.httpMethod = "GET"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw AuthError.network(message: "Non-HTTP response")
        }
        guard (200..<300).contains(http.statusCode) else {
            if http.statusCode == 401 { throw AuthError.notSignedIn }
            throw AuthError.serverFailure(status: http.statusCode, message: nil)
        }
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

    private func loadLastValidatedAt() -> Date? {
        guard let raw = (try? storage.load(.lastValidatedAt)) ?? nil,
              let seconds = TimeInterval(raw) else { return nil }
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
        _ = try await session.data(for: request)
    }
}
