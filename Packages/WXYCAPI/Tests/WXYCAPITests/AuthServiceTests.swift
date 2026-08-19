//
//  AuthServiceTests.swift
//  WXYCAPITests
//
//  Drives AuthService against a stub network: sign-in success grabs the
//  session token from the set-auth-token header, the JWT exchange decodes
//  claims, 401 on sign-in maps to invalidCredentials, and restoreSession
//  brings a stored token back to .signedIn. Also pins issue #53's
//  transient/terminal split: a real session whose JWT exchange fails
//  transiently enters the pending window (.signedIn(payload: nil)) and
//  re-mints the JWT lazily, while a 401 stays terminal and rolls back.
//
//  Issue #57 (offline auth grace): a successful exchange persists the grace
//  anchors (lastValidatedAt + a durable payload); a cold-launch restore whose
//  JWT exchange fails transiently consults OfflineSessionPolicy — within the
//  window it restores the cached identity (tokens retained), past the window it
//  signs out (tokens retained), and a 401 stays terminal (tokens cleared,
//  including the new anchors).
//
//  Created by Jake on 5/14/26.
//  Copyright © 2026 WXYC. All rights reserved.
//

import Foundation
import os
import Testing
@testable import WXYCAPI

@Suite("AuthService", .serialized)
@MainActor
struct AuthServiceTests {
    private static let config = WXYCAPIConfiguration.localDevelopment

    /// Thread-safe sink for the `AuthService` connectivity outcome hook (#71):
    /// records each `true`/`false` transport result in order. `Sendable`
    /// (lock-backed) so it can be captured in the `@Sendable` outcome closure —
    /// the same shape `APIClientTests` uses for `APIClient.onOutcome`.
    private final class OutcomeRecorder: Sendable {
        private let storage = OSAllocatedUnfairLock<[Bool]>(initialState: [])
        var values: [Bool] { storage.withLock { $0 } }
        func record(_ success: Bool) { storage.withLock { $0.append(success) } }
    }

    @Test func signInSuccessReachesSignedIn() async throws {
        let session = StubRequestSession()
        let storage = InMemoryTokenStorage()
        let service = AuthService(configuration: Self.config, storage: storage, session: session)

        session.enqueue(StubRequestSession.Stub(
            statusCode: 200,
            headers: ["set-auth-token": "session-abc"],
            body: Data("{}".utf8)
        ))
        session.enqueue(StubRequestSession.Stub(
            statusCode: 200,
            body: Data(#"{"token":"\#(Fixtures.jwt())"}"#.utf8)
        ))

        await service.signIn(identifier: "dj", password: "pw")

        guard case let .signedIn(payload) = service.state else {
            Issue.record("expected signedIn, got \(service.state)")
            return
        }
        // The happy path carries a real payload (not the issue-#53 pending nil).
        #expect(payload?.role == "dj")
        #expect(try storage.load(.sessionToken) == "session-abc")
    }

    @Test func isSignedInTracksState() async throws {
        let session = StubRequestSession()
        let storage = InMemoryTokenStorage()
        let service = AuthService(configuration: Self.config, storage: storage, session: session)

        // .unknown at construction.
        #expect(service.isSignedIn == false)

        session.enqueue(StubRequestSession.Stub(
            statusCode: 200,
            headers: ["set-auth-token": "session-abc"],
            body: Data("{}".utf8)
        ))
        session.enqueue(StubRequestSession.Stub(
            statusCode: 200,
            body: Data(#"{"token":"\#(Fixtures.jwt())"}"#.utf8)
        ))
        await service.signIn(identifier: "dj", password: "pw")
        #expect(service.isSignedIn == true)  // .signedIn

        await service.signOut()
        #expect(service.isSignedIn == false)  // .signedOut
    }

    @Test func stateIsSignedInFlag() {
        // The non-authenticated cases — the deep-link auth-change handler compares
        // old vs. new State.isSignedIn to tell a genuine sign-out from a
        // cold-launch .unknown → .signedOut. (.signedIn → true is covered by
        // isSignedInTracksState, which needs a real JWTPayload.)
        #expect(AuthService.State.unknown.isSignedIn == false)
        #expect(AuthService.State.signedOut.isSignedIn == false)
        #expect(AuthService.State.signingIn.isSignedIn == false)
    }

    @Test func signInFailureSurfacesInvalidCredentials() async throws {
        let session = StubRequestSession()
        let storage = InMemoryTokenStorage()
        let service = AuthService(configuration: Self.config, storage: storage, session: session)

        session.enqueue(StubRequestSession.Stub(
            statusCode: 401,
            body: Data(#"{"message":"nope"}"#.utf8)
        ))

        await service.signIn(identifier: "dj", password: "wrong")

        #expect(service.state == .signedOut)
        #expect(service.lastError == .invalidCredentials)
        #expect(try storage.load(.sessionToken) == nil)
    }

    // MARK: - Identifier routing (issue #97)

    @Test func emailIdentifierSignsInThroughTheEmailRoute() async throws {
        let session = StubRequestSession()
        let storage = InMemoryTokenStorage()
        let service = AuthService(configuration: Self.config, storage: storage, session: session)

        session.enqueue(StubRequestSession.Stub(
            statusCode: 200,
            headers: ["set-auth-token": "session-abc"],
            body: Data("{}".utf8)
        ))
        session.enqueue(StubRequestSession.Stub(
            statusCode: 200,
            body: Data(#"{"token":"\#(Fixtures.jwt())"}"#.utf8)
        ))

        await service.signIn(identifier: "juana@wxyc.org", password: "pw")

        // Before #97 this identifier never got as far as a credential check:
        // better-auth's username plugin rejected the `@` on shape alone with a
        // 422, so the DJ saw "Username is invalid" no matter the password.
        let signInRequest = try #require(session.recordedRequests.first)
        #expect(signInRequest.url?.path == "/auth/sign-in/email")
        let body = try #require(signInRequest.httpBody)
        let json = try #require(try JSONSerialization.jsonObject(with: body) as? [String: String])
        #expect(json == ["email": "juana@wxyc.org", "password": "pw"])

        // The rest of the handshake is the shared one: the bearer plugin emits
        // `set-auth-token` on this route too, so the JWT exchange and the
        // issue-#53 state machine behave exactly as on the username path.
        guard case let .signedIn(payload) = service.state else {
            Issue.record("expected signedIn, got \(service.state)")
            return
        }
        #expect(payload?.role == "dj")
        #expect(try storage.load(.sessionToken) == "session-abc")
    }

    @Test func usernameIdentifierKeepsTheUsernameRouteUnchanged() async throws {
        let session = StubRequestSession()
        let storage = InMemoryTokenStorage()
        let service = AuthService(configuration: Self.config, storage: storage, session: session)

        session.enqueue(StubRequestSession.Stub(
            statusCode: 200,
            headers: ["set-auth-token": "session-abc"],
            body: Data("{}".utf8)
        ))
        session.enqueue(StubRequestSession.Stub(
            statusCode: 200,
            body: Data(#"{"token":"\#(Fixtures.jwt())"}"#.utf8)
        ))

        await service.signIn(identifier: "juana", password: "pw")

        // Asserted on the wire, not at the type level: #97's contract is that a
        // username sign-in is byte-for-byte what it was, so a future refactor
        // that quietly re-keys this body has to fail here.
        let signInRequest = try #require(session.recordedRequests.first)
        #expect(signInRequest.url?.path == "/auth/sign-in/username")
        let body = try #require(signInRequest.httpBody)
        let json = try #require(try JSONSerialization.jsonObject(with: body) as? [String: String])
        #expect(json == ["username": "juana", "password": "pw"])
        #expect(service.isSignedIn)
    }

    @Test(arguments: [
        ("juana", "/auth/sign-in/username"),
        ("juana@wxyc.org", "/auth/sign-in/email"),
    ])
    func signInNeverCarriesACookie(identifier: String, expectedPath: String) async throws {
        let session = StubRequestSession()
        let service = AuthService(configuration: Self.config, storage: InMemoryTokenStorage(), session: session)

        session.enqueue(StubRequestSession.Stub(
            statusCode: 200,
            headers: ["set-auth-token": "session-abc"],
            body: Data("{}".utf8)
        ))
        session.enqueue(StubRequestSession.Stub(
            statusCode: 200,
            body: Data(#"{"token":"\#(Fixtures.jwt())"}"#.utf8)
        ))

        await service.signIn(identifier: identifier, password: "pw")

        // This client is bearer-only, and better-auth's `bearer()` after-hook
        // ADDS `set-auth-token` without removing the `Set-Cookie` it rides
        // alongside — so a default `URLSession` stores the session cookie and
        // replays it on the next sign-in. That is fatal: better-auth registers
        // `originCheckMiddleware` globally on every non-GET, and it enforces the
        // Origin header only when a cookie is present, so a cookie-bearing
        // sign-in from a native client (which sends no Origin) is refused with
        // `403 MISSING_OR_NULL_ORIGIN` before any credential check. Verified
        // against production on BOTH routes. Suppressing cookie handling keeps
        // the jar empty in both directions, so the request can never acquire the
        // header that arms that middleware.
        let signInRequest = try #require(session.recordedRequests.first)
        #expect(signInRequest.url?.path == expectedPath)
        #expect(signInRequest.httpShouldHandleCookies == false)
        // The JWT exchange rides the same transport and gets the same treatment.
        #expect(session.recordedRequests.last?.httpShouldHandleCookies == false)
    }

    @Test func forbiddenSurfacesItsReasonInsteadOfBlamingTheCredentials() async throws {
        let session = StubRequestSession()
        let storage = InMemoryTokenStorage()
        let service = AuthService(configuration: Self.config, storage: storage, session: session)

        // Backend-Service sets `requireEmailVerification: true`, so an
        // un-onboarded DJ gets a 403 whose message names the real problem.
        // Folding that into `.invalidCredentials` would have them retyping a
        // correct password forever — and it is what would have hidden a 403
        // from the origin middleware above.
        session.enqueue(StubRequestSession.Stub(
            statusCode: 403,
            body: Data(#"{"message":"Email not verified"}"#.utf8)
        ))

        await service.signIn(identifier: "juana@wxyc.org", password: "pw")

        #expect(service.state == .signedOut)
        #expect(service.lastError == .rejected(message: "Email not verified"))
        #expect(service.lastError?.localizedMessage == "Email not verified.")
        // Still terminal: nothing is left behind by a refused sign-in.
        #expect(try storage.load(.sessionToken) == nil)
    }

    @Test func malformedEmailSurfacesTheServerMessage() async throws {
        let session = StubRequestSession()
        let storage = InMemoryTokenStorage()
        let service = AuthService(configuration: Self.config, storage: storage, session: session)

        // What better-auth's /sign-in/email answers for an identifier that
        // fails its `z.email()` check — the payoff of routing on `@` rather
        // than on a full email regex, which would have sent this to the
        // username endpoint for a misleading "Username is invalid" instead.
        session.enqueue(StubRequestSession.Stub(
            statusCode: 400,
            body: Data(#"{"message":"Invalid email"}"#.utf8)
        ))

        await service.signIn(identifier: "juana@wxyc", password: "pw")

        #expect(service.state == .signedOut)
        #expect(service.lastError == .rejected(message: "Invalid email"))
        // Rendered verbatim, not behind a "Server error (400):" prefix — the DJ
        // mistyped their address; that is not a backend fault.
        #expect(service.lastError?.localizedMessage == "Invalid email.")
        #expect(try storage.load(.sessionToken) == nil)
    }

    @Test func signInWithFailedJWTExchangeLeavesNoStoredToken() async throws {
        // The two-leg handshake: /auth/sign-in/username succeeds (session token
        // issued + persisted), then /auth/token returns 401 — the session bearer
        // is rejected, so the session is genuinely dead. This is the *terminal*
        // arm (issue #53): we report the sign-in as failed and it must leave NO
        // durable trace. Otherwise the orphaned session token sits in the
        // Keychain and the next cold launch's restoreSession() finds it, and a
        // failed login silently logs the user straight in on reopen. Preserves
        // #52's leave-no-trace guarantee — re-pointed from a 503 to a 401, since
        // a 503 is now the *transient* (pending) path, not terminal.
        let session = StubRequestSession()
        let storage = InMemoryTokenStorage()
        let service = AuthService(configuration: Self.config, storage: storage, session: session)

        // Leg 1: sign-in succeeds, session token captured from the header.
        session.enqueue(StubRequestSession.Stub(
            statusCode: 200,
            headers: ["set-auth-token": "session-abc"],
            body: Data("{}".utf8)
        ))
        // Leg 2: JWT exchange returns 401 — dead session, terminal.
        session.enqueue(StubRequestSession.Stub(statusCode: 401, body: Data()))

        await service.signIn(identifier: "dj", password: "pw")

        #expect(service.state == .signedOut)
        #expect(service.lastError == .notSignedIn)
        // The load-bearing assertion: a terminally-failed sign-in persists nothing.
        #expect(try storage.load(.sessionToken) == nil)
        #expect(try storage.load(.jwt) == nil)
    }

    @Test func signInWithUndecodableJWTBodyEntersPendingAndKeepsSession() async throws {
        // 2xx-but-undecodable JWT body: /auth/token returns 2xx (the server
        // authenticated the bearer) and rotates the session token
        // (captureRotatedSessionToken persists it) but the body fails to decode —
        // a server-side defect, not a dead session. Under issue #53 this is now a
        // *transient* path: enter the pending window keeping the (rotated)
        // session token, and re-mint the JWT lazily. (Previously this rolled the
        // sign-in back; the meaning flipped with the transient/terminal split.)
        let session = StubRequestSession()
        let storage = InMemoryTokenStorage()
        let service = AuthService(configuration: Self.config, storage: storage, session: session)

        session.enqueue(StubRequestSession.Stub(
            statusCode: 200,
            headers: ["set-auth-token": "session-abc"],
            body: Data("{}".utf8)
        ))
        // 2xx with a rotation header but a body that isn't a valid JWTResponse.
        session.enqueue(StubRequestSession.Stub(
            statusCode: 200,
            headers: ["set-auth-token": "session-rotated"],
            body: Data("not json".utf8)
        ))

        await service.signIn(identifier: "dj", password: "pw")

        // Pending: signed in with no payload yet.
        #expect(service.state == .signedIn(payload: nil))
        #expect(service.lastError == nil)
        // The rotated session token is the credential and must be retained.
        #expect(try storage.load(.sessionToken) == "session-rotated")
        // No JWT was decoded, so none is persisted.
        #expect(try storage.load(.jwt) == nil)
    }

    @Test func signInWithTransientServerErrorEntersPending() async throws {
        // 200 sign-in then 503 on /auth/token: the session is established and
        // real, the JWT exchange just hit a transient server error. Issue #53:
        // do NOT bounce back to login — enter the pending window keeping the
        // persisted session token, so currentJWT() can re-mint the JWT lazily.
        let session = StubRequestSession()
        let storage = InMemoryTokenStorage()
        let service = AuthService(configuration: Self.config, storage: storage, session: session)

        session.enqueue(StubRequestSession.Stub(
            statusCode: 200,
            headers: ["set-auth-token": "session-abc"],
            body: Data("{}".utf8)
        ))
        session.enqueue(StubRequestSession.Stub(statusCode: 503, body: Data()))

        await service.signIn(identifier: "dj", password: "pw")

        #expect(service.state == .signedIn(payload: nil))
        #expect(service.lastError == nil)
        #expect(try storage.load(.sessionToken) == "session-abc")
    }

    @Test func signInWithNetworkErrorOnJWTExchangeEntersPending() async throws {
        // 200 sign-in then a transport-level failure on /auth/token (here: the
        // stub runs out of canned responses, so session.data(for:) throws — the
        // same shape as an offline/timeout URLError a real device would see).
        // A non-AuthError throw from the JWT leg is transient → pending window.
        let session = StubRequestSession()
        let storage = InMemoryTokenStorage()
        let service = AuthService(configuration: Self.config, storage: storage, session: session)

        // Only Leg 1 is stubbed; the /auth/token call throws (no more stubs).
        session.enqueue(StubRequestSession.Stub(
            statusCode: 200,
            headers: ["set-auth-token": "session-abc"],
            body: Data("{}".utf8)
        ))

        await service.signIn(identifier: "dj", password: "pw")

        #expect(service.state == .signedIn(payload: nil))
        #expect(service.lastError == nil)
        #expect(try storage.load(.sessionToken) == "session-abc")
    }

    @Test func pendingSignInResolvesViaLazyJWTRefresh() async throws {
        // After entering the pending window, the first currentJWT() re-mints the
        // JWT: a queued 200 /auth/token succeeds, currentJWT() returns the token,
        // and the DJ stays signed in (state untouched — no onChange churn).
        let session = StubRequestSession()
        let storage = InMemoryTokenStorage()
        let service = AuthService(configuration: Self.config, storage: storage, session: session)

        session.enqueue(StubRequestSession.Stub(
            statusCode: 200,
            headers: ["set-auth-token": "session-abc"],
            body: Data("{}".utf8)
        ))
        session.enqueue(StubRequestSession.Stub(statusCode: 503, body: Data()))
        await service.signIn(identifier: "dj", password: "pw")
        #expect(service.state == .signedIn(payload: nil))
        let requestsBeforeRetry = session.recordedRequests.count

        // The lazy retry: /auth/token now succeeds.
        session.enqueue(StubRequestSession.Stub(
            statusCode: 200,
            body: Data(#"{"token":"\#(Fixtures.jwt())"}"#.utf8)
        ))
        let token = try await service.currentJWT()

        #expect(!token.isEmpty)
        #expect(service.isSignedIn)  // still signed in
        // Exactly one extra request (the lazy /auth/token retry).
        #expect(session.recordedRequests.count == requestsBeforeRetry + 1)
    }

    @Test func pendingSignInDemotesToSignedOutOnLazy401() async throws {
        // After entering the pending window, if the lazy JWT retry returns 401
        // the session is proven dead: currentJWT() demotes to .signedOut and
        // clears the tokens, so RootView swaps MainView → LoginView rather than
        // stranding the DJ. (The way back out of the pending window.)
        let session = StubRequestSession()
        let storage = InMemoryTokenStorage()
        let service = AuthService(configuration: Self.config, storage: storage, session: session)

        session.enqueue(StubRequestSession.Stub(
            statusCode: 200,
            headers: ["set-auth-token": "session-abc"],
            body: Data("{}".utf8)
        ))
        session.enqueue(StubRequestSession.Stub(statusCode: 503, body: Data()))
        await service.signIn(identifier: "dj", password: "pw")
        #expect(service.state == .signedIn(payload: nil))

        // The lazy retry returns 401 — dead session.
        session.enqueue(StubRequestSession.Stub(statusCode: 401, body: Data()))
        await #expect(throws: AuthError.notSignedIn) {
            _ = try await service.currentJWT()
        }

        #expect(service.state == .signedOut)
        #expect(service.lastError == .notSignedIn)
        #expect(try storage.load(.sessionToken) == nil)
        #expect(try storage.load(.jwt) == nil)
    }

    @Test func signedInSessionDemotesWhenLazyRefreshHits401() async throws {
        // The latent-gap regression: a healthy session (real payload) that the
        // server later revokes. The next currentJWT() after the cached JWT is
        // dropped re-exchanges, gets a 401, and demotes to .signedOut + clears
        // tokens — closing the pre-existing gap where a revoked-mid-use session
        // left state pinned at .signedIn forever.
        let session = StubRequestSession()
        let storage = InMemoryTokenStorage()
        let service = AuthService(configuration: Self.config, storage: storage, session: session)

        session.enqueue(StubRequestSession.Stub(
            statusCode: 200,
            headers: ["set-auth-token": "session-abc"],
            body: Data("{}".utf8)
        ))
        session.enqueue(StubRequestSession.Stub(
            statusCode: 200,
            body: Data(#"{"token":"\#(Fixtures.jwt())"}"#.utf8)
        ))
        await service.signIn(identifier: "dj", password: "pw")
        guard case let .signedIn(payload) = service.state, payload != nil else {
            Issue.record("expected a payload-bearing signedIn, got \(service.state)")
            return
        }

        // Force the cached JWT stale so the next currentJWT() re-exchanges.
        service.invalidateJWT()
        // The session has been revoked: /auth/token now 401s.
        session.enqueue(StubRequestSession.Stub(statusCode: 401, body: Data()))
        await #expect(throws: AuthError.notSignedIn) {
            _ = try await service.currentJWT()
        }

        #expect(service.state == .signedOut)
        #expect(try storage.load(.sessionToken) == nil)
        #expect(try storage.load(.jwt) == nil)
    }

    @Test func currentJWTTransientFailureLeavesStateSignedIn() async throws {
        // A *transient* lazy-refresh failure (5xx, not 401) must propagate the
        // error WITHOUT demoting: the session may still be good, so state stays
        // .signedIn and the calling view shows a retryable error (no bounce to
        // login). The complement of the lazy-401 demotion tests.
        let session = StubRequestSession()
        let storage = InMemoryTokenStorage()
        let service = AuthService(configuration: Self.config, storage: storage, session: session)

        // Reach the pending window via a sign-in whose JWT leg 503s.
        session.enqueue(StubRequestSession.Stub(
            statusCode: 200,
            headers: ["set-auth-token": "session-abc"],
            body: Data("{}".utf8)
        ))
        session.enqueue(StubRequestSession.Stub(statusCode: 503, body: Data()))
        await service.signIn(identifier: "dj", password: "pw")
        #expect(service.state == .signedIn(payload: nil))

        // The lazy retry hits another 503 — still transient, still no demotion.
        session.enqueue(StubRequestSession.Stub(statusCode: 503, body: Data()))
        await #expect(throws: AuthError.serverFailure(status: 503, message: nil)) {
            _ = try await service.currentJWT()
        }

        #expect(service.state == .signedIn(payload: nil))
        #expect(try storage.load(.sessionToken) == "session-abc")
    }

    @Test func lazyRefresh401ForASupersededBearerDoesNotClobberANewSession() async throws {
        // The issue-#53 concurrency guard. currentJWT() is the shared lazy-refresh
        // chokepoint for every authed caller (interactive search/bin AND the
        // background catalog refresh share one AuthService), so two refreshes can
        // overlap, each bound to its own bearer. If a stale refresh resumes with a
        // 401 *after* a concurrent re-sign-in already replaced the session, the
        // demotion must NOT fire — clobbering would erase the valid new session
        // and spuriously bounce the DJ to login. The GatedAuthSession parks the
        // stale refresh's /auth/token mid-flight so the race is deterministic.
        let session = GatedAuthSession()
        let storage = InMemoryTokenStorage()
        try storage.save("session-1", for: .sessionToken)
        let service = AuthService(configuration: Self.config, storage: storage, session: session)

        // Cold-launch restore brings session-1 to .signedIn (one instant token call).
        session.enqueueInstant(StubRequestSession.Stub(
            statusCode: 200,
            body: Data(#"{"token":"\#(Fixtures.jwt())"}"#.utf8)
        ))
        await service.restoreSession()
        service.invalidateJWT()  // force the next currentJWT() to hit the network

        // Arm the gate so the stale refresh's /auth/token parks, then 401s.
        session.armGate(returning: StubRequestSession.Stub(statusCode: 401, body: Data()))
        // The concurrent re-sign-in's responses (served instantly): a fresh session-2.
        session.enqueueInstant(StubRequestSession.Stub(
            statusCode: 200,
            headers: ["set-auth-token": "session-2"],
            body: Data("{}".utf8)
        ))
        session.enqueueInstant(StubRequestSession.Stub(
            statusCode: 200,
            body: Data(#"{"token":"\#(Fixtures.jwt())"}"#.utf8)
        ))

        // Start the stale refresh (bound to session-1); it parks at the gate.
        let staleRefresh = Task { try? await service.currentJWT() }
        await session.waitForGatedArrival()

        // While the stale refresh is suspended, the DJ re-signs-in to session-2.
        await service.signIn(identifier: "dj", password: "pw")
        #expect(service.isSignedIn)
        #expect(try storage.load(.sessionToken) == "session-2")

        // Let the stale refresh resume: its 401 is for the superseded session-1.
        session.releaseGate()
        _ = await staleRefresh.value

        // The guard suppressed the demotion: the new session-2 survives intact.
        guard case let .signedIn(payload) = service.state else {
            Issue.record("expected still signedIn, got \(service.state)")
            return
        }
        #expect(payload != nil)  // session-2's real JWT — not demoted, not pending
        #expect(try storage.load(.sessionToken) == "session-2")
        #expect(try storage.load(.jwt) != nil)
    }

    @Test func signOutDuringInFlightRefreshIsNotResurrectedByRotationHeader() async throws {
        // Issue #66 — the success-path mirror of the lazy-401 guard above. The
        // refresh binds its bearer and suspends at /auth/token; if a signOut runs
        // during that suspension (clearing the token, the Keychain, and state),
        // the refresh must NOT resume on a 2xx and re-persist the session. The
        // dangerous variant carries a rolling-renewal `set-auth-token` rotation
        // header: captureRotatedSessionToken would see it differ from the now-nil
        // sessionToken and write it back to the Keychain — leaving state ==
        // .signedOut but a live bearer persisted, which the next cold launch's
        // restoreSession() silently signs back in. That defeats signOut and
        // violates #52's leave-no-trace contract (security-relevant on a shared
        // device). The GatedAuthSession parks the refresh mid-flight so the
        // signOut interleaves deterministically.
        let session = GatedAuthSession()
        let storage = InMemoryTokenStorage()
        try storage.save("session-1", for: .sessionToken)
        let service = AuthService(configuration: Self.config, storage: storage, session: session)

        // Cold-launch restore brings session-1 to .signedIn (one instant token call).
        session.enqueueInstant(StubRequestSession.Stub(
            statusCode: 200,
            body: Data(#"{"token":"\#(Fixtures.jwt())"}"#.utf8)
        ))
        await service.restoreSession()
        service.invalidateJWT()  // force the next currentJWT() to hit the network

        // Arm the gate so the refresh's /auth/token parks, then returns a 2xx
        // that BOTH rotates the session (set-auth-token) and carries a valid JWT.
        session.armGate(returning: StubRequestSession.Stub(
            statusCode: 200,
            headers: ["set-auth-token": "session-2"],
            body: Data(#"{"token":"\#(Fixtures.jwt())"}"#.utf8)
        ))

        // Start the refresh (bound to session-1); it parks at the gate.
        let refresh = Task { try? await service.currentJWT() }
        await session.waitForGatedArrival()

        // While the refresh is suspended, the DJ signs out: token + Keychain
        // cleared, state .signedOut.
        await service.signOut()
        #expect(service.state == .signedOut)

        // Let the refresh resume on its 2xx + rotation header.
        session.releaseGate()
        _ = await refresh.value

        // The load-bearing assertions: the signed-out session stays signed out
        // with an EMPTY Keychain — the rotation header did not resurrect it.
        #expect(service.state == .signedOut)
        #expect(try storage.load(.sessionToken) == nil)
        #expect(try storage.load(.jwt) == nil)
    }

    @Test func benignConcurrentDoubleRefreshDoesNotSpuriouslyFail() async throws {
        // Issue #66 regression guard. The fix must reject a signOut/replace that
        // races a refresh WITHOUT regressing the benign overlapping double-refresh
        // — two authed callers (interactive search/bin AND the background catalog
        // refresh share one AuthService) racing a refresh, where the first merely
        // *rotates* the session while the second is awaiting. A naive
        // `guard sessionToken == boundToken` would make the second spuriously
        // throw .notSignedIn even though the session is alive. The epoch guard
        // doesn't bump on rotation, so both callers still resolve a JWT.
        let session = GatedAuthSession()
        let storage = InMemoryTokenStorage()
        try storage.save("session-1", for: .sessionToken)
        let service = AuthService(configuration: Self.config, storage: storage, session: session)

        // Cold-launch restore brings session-1 to .signedIn.
        session.enqueueInstant(StubRequestSession.Stub(
            statusCode: 200,
            body: Data(#"{"token":"\#(Fixtures.jwt())"}"#.utf8)
        ))
        await service.restoreSession()
        service.invalidateJWT()

        // Refresh A parks at the gate (bound to session-1); it resumes LAST, after
        // refresh B has already rotated the live session to session-2.
        session.armGate(returning: StubRequestSession.Stub(
            statusCode: 200,
            body: Data(#"{"token":"\#(Fixtures.jwt())"}"#.utf8)
        ))
        // Refresh B (served instantly) rotates session-1 → session-2.
        session.enqueueInstant(StubRequestSession.Stub(
            statusCode: 200,
            headers: ["set-auth-token": "session-2"],
            body: Data(#"{"token":"\#(Fixtures.jwt())"}"#.utf8)
        ))

        let refreshA = Task { try await service.currentJWT() }
        await session.waitForGatedArrival()

        // While A is parked, B runs to completion and rotates the session.
        let bToken = try await service.currentJWT()
        #expect(!bToken.isEmpty)
        #expect(try storage.load(.sessionToken) == "session-2")

        // A resumes: the live session was rotated to session-2 (same generation),
        // not cleared. A must still resolve a JWT — no spurious .notSignedIn.
        session.releaseGate()
        let aToken = try await refreshA.value  // rethrows if A spuriously failed
        #expect(!aToken.isEmpty)
        #expect(service.isSignedIn)
        #expect(try storage.load(.sessionToken) == "session-2")
    }

    @Test func restoreSessionPullsTokenFromStorage() async throws {
        let session = StubRequestSession()
        let storage = InMemoryTokenStorage()
        try storage.save("session-existing", for: .sessionToken)
        let service = AuthService(configuration: Self.config, storage: storage, session: session)

        session.enqueue(StubRequestSession.Stub(
            statusCode: 200,
            body: Data(#"{"token":"\#(Fixtures.jwt())"}"#.utf8)
        ))

        await service.restoreSession()

        if case let .signedIn(payload) = service.state {
            #expect(payload?.email == "juana@wxyc.org")
        } else {
            Issue.record("expected signedIn, got \(service.state)")
        }
    }

    @Test func signOutClearsLocalStateEvenWhenNetworkCallFails() async throws {
        // The remote /auth/sign-out is best-effort: if the server is
        // unreachable, we still want the device to forget the session.
        // Otherwise a stale offline state can pin the user "signed in" with
        // a long-dead token.
        let session = StubRequestSession()
        let storage = InMemoryTokenStorage()
        try storage.save("session-abc", for: .sessionToken)
        try storage.save("jwt-old", for: .jwt)
        let service = AuthService(configuration: Self.config, storage: storage, session: session)

        // restoreSession needs a JWT exchange to succeed first
        session.enqueue(StubRequestSession.Stub(
            statusCode: 200,
            body: Data(#"{"token":"\#(Fixtures.jwt())"}"#.utf8)
        ))
        await service.restoreSession()

        // Network sign-out fails (server down): stub a 500.
        session.enqueue(StubRequestSession.Stub(statusCode: 500, body: Data()))
        await service.signOut()

        #expect(service.state == .signedOut)
        #expect(try storage.load(.sessionToken) == nil)
        #expect(try storage.load(.jwt) == nil)
    }

    @Test func signOutClearsStateAndStorage() async throws {
        let session = StubRequestSession()
        let storage = InMemoryTokenStorage()
        try storage.save("session-abc", for: .sessionToken)
        try storage.save("jwt-old", for: .jwt)
        let service = AuthService(configuration: Self.config, storage: storage, session: session)

        // restore so service has the session in memory
        session.enqueue(StubRequestSession.Stub(
            statusCode: 200,
            body: Data(#"{"token":"\#(Fixtures.jwt())"}"#.utf8)
        ))
        await service.restoreSession()

        // sign-out POST (response ignored)
        session.enqueue(StubRequestSession.Stub(statusCode: 200))
        await service.signOut()

        #expect(service.state == .signedOut)
        #expect(try storage.load(.sessionToken) == nil)
        #expect(try storage.load(.jwt) == nil)

        // Pin the wire contract: signOut must hit POST /auth/sign-out with
        // the session bearer. better-auth's sign-out endpoint accepts the
        // bearer plugin's token; getting the URL or method wrong silently
        // leaves a live session on the server.
        let signOutRequest = try #require(session.recordedRequests.last)
        #expect(signOutRequest.httpMethod == "POST")
        #expect(signOutRequest.url?.path == "/auth/sign-out")
        #expect(signOutRequest.value(forHTTPHeaderField: "Authorization") == "Bearer session-abc")
    }

    @Test func refreshJWTCapturesRotatedSessionTokenFromHeader() async throws {
        // better-auth's bearer plugin emits `set-auth-token` whenever the
        // session is refreshed (roughly once per session.updateAge, default
        // 24h). If iOS keeps using the previous bearer, the next /auth/token
        // call will 401 and the user is silently signed out. Confirm that
        // refreshJWT picks the rotated token up.
        let session = StubRequestSession()
        let storage = InMemoryTokenStorage()
        try storage.save("session-old", for: .sessionToken)
        let service = AuthService(configuration: Self.config, storage: storage, session: session)

        session.enqueue(StubRequestSession.Stub(
            statusCode: 200,
            headers: ["set-auth-token": "session-new"],
            body: Data(#"{"token":"\#(Fixtures.jwt())"}"#.utf8)
        ))

        await service.restoreSession()

        guard case .signedIn = service.state else {
            Issue.record("expected signedIn, got \(service.state)")
            return
        }
        #expect(try storage.load(.sessionToken) == "session-new")

        // The captured token must also be in-memory: the next sign-out call
        // (which sends Authorization: Bearer <sessionToken>) should use it.
        session.enqueue(StubRequestSession.Stub(statusCode: 200))
        await service.signOut()
        let signOutRequest = try #require(session.recordedRequests.last)
        #expect(signOutRequest.value(forHTTPHeaderField: "Authorization") == "Bearer session-new")
    }

    @Test func refreshJWTLeavesSessionTokenAloneWhenHeaderAbsent() async throws {
        // No rotation header → don't touch the stored bearer.
        let session = StubRequestSession()
        let storage = InMemoryTokenStorage()
        try storage.save("session-stable", for: .sessionToken)
        let service = AuthService(configuration: Self.config, storage: storage, session: session)

        session.enqueue(StubRequestSession.Stub(
            statusCode: 200,
            body: Data(#"{"token":"\#(Fixtures.jwt())"}"#.utf8)
        ))

        await service.restoreSession()
        #expect(try storage.load(.sessionToken) == "session-stable")
    }

    @Test func refreshJWTIgnoresEmptyRotationHeader() async throws {
        // An empty `set-auth-token` value (which would brick the session if
        // saved) must be treated as "no rotation".
        let session = StubRequestSession()
        let storage = InMemoryTokenStorage()
        try storage.save("session-stable", for: .sessionToken)
        let service = AuthService(configuration: Self.config, storage: storage, session: session)

        session.enqueue(StubRequestSession.Stub(
            statusCode: 200,
            headers: ["set-auth-token": ""],
            body: Data(#"{"token":"\#(Fixtures.jwt())"}"#.utf8)
        ))

        await service.restoreSession()
        #expect(try storage.load(.sessionToken) == "session-stable")
    }

    @Test func restoreSessionTransientWithoutGraceAnchorSignsOutButKeepsToken() async throws {
        // Cold launch with a *bare* stored token (no grace anchor — e.g. a
        // legacy install upgrading to issue #57, or a payload/anchor that never
        // got persisted), /auth/token fails transiently (503). Without an
        // anchor the OfflineSessionPolicy can't grant grace, so it fails closed
        // to .signedOut. But a transient failure must NEVER clear tokens: the
        // session token is retained so the *next* online launch can recover the
        // session (success) or terminally clear it (401).
        let session = StubRequestSession()
        let storage = InMemoryTokenStorage()
        try storage.save("session-stored", for: .sessionToken)
        let service = AuthService(configuration: Self.config, storage: storage, session: session)

        session.enqueue(StubRequestSession.Stub(statusCode: 503, body: Data()))

        await service.restoreSession()

        #expect(service.state == .signedOut)
        // The transient branch keeps the token (no clearLocalSession).
        #expect(try storage.load(.sessionToken) == "session-stored")
    }

    @Test func restoreSessionOfflineWithinWindowKeepsCachedIdentity() async throws {
        // Issue #57, the headline case: a returning DJ cold-launches offline.
        // A prior online sign-in persisted the durable payload + a recent
        // lastValidatedAt anchor. Now /auth/token fails with a transport error
        // (the stub queue is left empty so data(for:) throws). Within the 30-day
        // window the DJ stays signed in on the cached identity — NOT the pending
        // nil, the real payload — and lands in the app, not the login screen.
        let session = StubRequestSession()
        let storage = InMemoryTokenStorage()

        // A real online sign-in seeds the anchors through the production path.
        session.enqueue(StubRequestSession.Stub(
            statusCode: 200,
            headers: ["set-auth-token": "session-abc"],
            body: Data("{}".utf8)
        ))
        session.enqueue(StubRequestSession.Stub(
            statusCode: 200,
            body: Data(#"{"token":"\#(Fixtures.jwt())"}"#.utf8)
        ))
        let first = AuthService(configuration: Self.config, storage: storage, session: session)
        await first.signIn(identifier: "dj", password: "pw")
        #expect(first.isSignedIn)
        #expect((try storage.load(.payload)) != nil)
        #expect((try storage.load(.lastValidatedAt)) != nil)

        // Cold launch (fresh AuthService, state .unknown). No stub enqueued →
        // the /auth/token exchange throws a transport error (offline blip).
        let second = AuthService(configuration: Self.config, storage: storage, session: session)
        await second.restoreSession()

        guard case let .signedIn(payload) = second.state else {
            Issue.record("expected signedIn, got \(second.state)")
            return
        }
        // The full cached identity round-trips through storage (sub/email/role +
        // a finite exp), not just email and not the issue-#53 pending nil. Pins
        // the JWTPayload encode/decode fidelity on the offline-restore path.
        #expect(payload != nil)
        #expect(payload?.sub == "42")
        #expect(payload?.email == "juana@wxyc.org")
        #expect(payload?.role == "dj")
        #expect(payload?.exp.timeIntervalSince1970.isFinite == true)
        // Tokens retained for a later online self-heal.
        #expect(try storage.load(.sessionToken) == "session-abc")
        #expect((try storage.load(.payload)) != nil)
    }

    @Test func restoreSessionOfflineBeyondWindowSignsOut() async throws {
        // Issue #57: same setup, but the last confirmed server contact is older
        // than the 30-day window. The grace has elapsed, so a cold launch whose
        // JWT exchange fails transiently drops to the login screen. Tokens are
        // still retained (a transient failure never clears them).
        let session = StubRequestSession()
        let storage = InMemoryTokenStorage()

        session.enqueue(StubRequestSession.Stub(
            statusCode: 200,
            headers: ["set-auth-token": "session-abc"],
            body: Data("{}".utf8)
        ))
        session.enqueue(StubRequestSession.Stub(
            statusCode: 200,
            body: Data(#"{"token":"\#(Fixtures.jwt())"}"#.utf8)
        ))
        let first = AuthService(configuration: Self.config, storage: storage, session: session)
        await first.signIn(identifier: "dj", password: "pw")

        // Backdate the anchor just past the window.
        let stale = Date().addingTimeInterval(-(OfflineSessionPolicy.defaultWindow + 60))
        try storage.save(String(stale.timeIntervalSince1970), for: .lastValidatedAt)

        // Cold launch offline: no stub → transport error.
        let second = AuthService(configuration: Self.config, storage: storage, session: session)
        await second.restoreSession()

        #expect(second.state == .signedOut)
        // Beyond-window sign-out is not a 401: tokens are not cleared.
        #expect(try storage.load(.sessionToken) == "session-abc")
    }

    @Test func restoreSessionWith401ClearsStoredTokenAndGraceAnchors() async throws {
        // Cold launch with a stored token that the server rejects (401): the
        // session is dead. Issue #53 makes this terminal arm clear the token —
        // previously restoreSession's catch-all kept it, so a revoked session
        // lingered in the Keychain and 401'd on every launch forever. Issue #57
        // adds: the grace anchors (lastValidatedAt + durable payload) are wiped
        // too, so a dead session can't be revived offline by the policy.
        let session = StubRequestSession()
        let storage = InMemoryTokenStorage()
        try storage.save("session-revoked", for: .sessionToken)
        // Pre-seed the grace anchors as if a prior contact had succeeded.
        let payload = JWTPayload(sub: "42", email: "juana@wxyc.org", role: "dj", exp: Date().addingTimeInterval(600))
        try storage.save(String(data: try JSONCoders.encoder.encode(payload), encoding: .utf8)!, for: .payload)
        try storage.save(String(Date().timeIntervalSince1970), for: .lastValidatedAt)
        let service = AuthService(configuration: Self.config, storage: storage, session: session)

        session.enqueue(StubRequestSession.Stub(statusCode: 401, body: Data()))

        await service.restoreSession()

        #expect(service.state == .signedOut)
        #expect(try storage.load(.sessionToken) == nil)
        #expect(try storage.load(.jwt) == nil)
        #expect((try storage.load(.lastValidatedAt)) == nil)
        #expect((try storage.load(.payload)) == nil)
    }

    @Test func restoreSessionOfflineWithCorruptedAnchorSignsOut() async throws {
        // Issue #57 fail-closed: a non-numeric / non-finite .lastValidatedAt
        // (storage corruption or tampering) must read as "no usable anchor" and
        // sign out, never crash or grant grace. Covers loadLastValidatedAt's
        // TimeInterval(raw)==nil and !isFinite branches end-to-end through
        // restoreSession. Tokens are retained (transient, not a 401).
        for corrupt in ["not-a-number", "inf", "infinity", ""] {
            let session = StubRequestSession()
            let storage = InMemoryTokenStorage()
            try storage.save("session-abc", for: .sessionToken)
            let payload = JWTPayload(sub: "42", email: "juana@wxyc.org", role: "dj", exp: Date().addingTimeInterval(600))
            try storage.save(String(data: try JSONCoders.encoder.encode(payload), encoding: .utf8)!, for: .payload)
            try storage.save(corrupt, for: .lastValidatedAt)
            let service = AuthService(configuration: Self.config, storage: storage, session: session)

            // No stub → /auth/token throws a transport error (transient).
            await service.restoreSession()

            #expect(service.state == .signedOut, "corrupt anchor \"\(corrupt)\" should fail closed")
            #expect(try storage.load(.sessionToken) == "session-abc")
        }
    }

    @Test func restoreSessionOfflineWithCorruptedPayloadSignsOut() async throws {
        // Issue #57 fail-closed: a garbage .payload blob (truncated JSON or a
        // schema-drifted shape) makes loadPersistedPayload return nil, so the
        // policy can't grant grace — sign out rather than revive a partial
        // identity. Tokens retained (transient).
        let session = StubRequestSession()
        let storage = InMemoryTokenStorage()
        try storage.save("session-abc", for: .sessionToken)
        try storage.save("{ this is not valid json", for: .payload)
        try storage.save(String(Date().timeIntervalSince1970), for: .lastValidatedAt)
        let service = AuthService(configuration: Self.config, storage: storage, session: session)

        await service.restoreSession()

        #expect(service.state == .signedOut)
        #expect(try storage.load(.sessionToken) == "session-abc")
    }

    @Test func signInPersistsGraceAnchorsAndRefreshUpdatesThem() async throws {
        // Issue #57: a successful sign-in persists lastValidatedAt + the durable
        // payload, and a later successful refresh advances lastValidatedAt — so
        // every confirmed server contact resets the grace window.
        let session = StubRequestSession()
        let storage = InMemoryTokenStorage()
        let service = AuthService(configuration: Self.config, storage: storage, session: session)

        session.enqueue(StubRequestSession.Stub(
            statusCode: 200,
            headers: ["set-auth-token": "session-abc"],
            body: Data("{}".utf8)
        ))
        session.enqueue(StubRequestSession.Stub(
            statusCode: 200,
            body: Data(#"{"token":"\#(Fixtures.jwt())"}"#.utf8)
        ))
        let before = Date().timeIntervalSince1970
        await service.signIn(identifier: "dj", password: "pw")

        let t1raw = try #require((try storage.load(.lastValidatedAt)))
        let t1 = try #require(TimeInterval(t1raw))
        #expect(t1 >= before)
        let payloadJSON = try #require((try storage.load(.payload)))
        let restored = try JSONCoders.decoder.decode(JWTPayload.self, from: Data(payloadJSON.utf8))
        #expect(restored.email == "juana@wxyc.org")
        #expect(restored.role == "dj")

        // Force a later refresh; the anchor must advance past t1.
        try await Task.sleep(for: .milliseconds(20))
        service.invalidateJWT()
        session.enqueue(StubRequestSession.Stub(
            statusCode: 200,
            body: Data(#"{"token":"\#(Fixtures.jwt())"}"#.utf8)
        ))
        _ = try await service.currentJWT()

        let t2raw = try #require((try storage.load(.lastValidatedAt)))
        let t2 = try #require(TimeInterval(t2raw))
        #expect(t2 > t1)  // the grace window reset on the refresh
    }

    @Test func signInClearsAStaleIdentitysGraceAnchorsOnEntry() async throws {
        // Issue #57 hardening: signIn must not let a *prior* DJ's grace anchors
        // (.payload + .lastValidatedAt) survive into a new DJ's session. If DJ A
        // is signed in (anchors = A) and signIn is then called for DJ B whose
        // session establishes (leg 1) but whose JWT exchange fails transiently
        // (leg 2) — so B never persists its own anchors — A's durable payload
        // would otherwise linger alongside B's session token. A later offline
        // restore would then pair B's bearer with A's cached identity. signIn
        // clears the anchors at entry, so the stale identity can't be revived.
        let session = StubRequestSession()
        let storage = InMemoryTokenStorage()

        // DJ A: full sign-in seeds anchors through the production path.
        session.enqueue(StubRequestSession.Stub(
            statusCode: 200,
            headers: ["set-auth-token": "session-A"],
            body: Data("{}".utf8)
        ))
        session.enqueue(StubRequestSession.Stub(
            statusCode: 200,
            body: Data(#"{"token":"\#(Fixtures.jwt())"}"#.utf8)
        ))
        let service = AuthService(configuration: Self.config, storage: storage, session: session)
        await service.signIn(identifier: "dj-a", password: "pw")
        #expect((try storage.load(.payload)) != nil)
        #expect((try storage.load(.lastValidatedAt)) != nil)

        // DJ B: leg 1 establishes a new session, leg 2 (the JWT exchange) fails
        // transiently — only one stub, so the /auth/token call throws.
        session.enqueue(StubRequestSession.Stub(
            statusCode: 200,
            headers: ["set-auth-token": "session-B"],
            body: Data("{}".utf8)
        ))
        await service.signIn(identifier: "dj-b", password: "pw")

        // B's session token is live, but A's anchors must be gone — not lingering.
        #expect(try storage.load(.sessionToken) == "session-B")
        #expect(service.state == .signedIn(payload: nil))  // pending window for B
        #expect((try storage.load(.payload)) == nil)
        #expect((try storage.load(.lastValidatedAt)) == nil)
    }

    @Test func invalidateJWTLeavesDurablePayloadIntact() async throws {
        // Issue #57: invalidateJWT() (the transient eviction APIClient fires on
        // a 401, and the cache-stale path) clears the cached JWT + the .jwt slot
        // but must NOT touch the durable .payload slot the grace path relies on.
        let session = StubRequestSession()
        let storage = InMemoryTokenStorage()
        let service = AuthService(configuration: Self.config, storage: storage, session: session)

        session.enqueue(StubRequestSession.Stub(
            statusCode: 200,
            headers: ["set-auth-token": "session-abc"],
            body: Data("{}".utf8)
        ))
        session.enqueue(StubRequestSession.Stub(
            statusCode: 200,
            body: Data(#"{"token":"\#(Fixtures.jwt())"}"#.utf8)
        ))
        await service.signIn(identifier: "dj", password: "pw")
        #expect((try storage.load(.jwt)) != nil)
        #expect((try storage.load(.payload)) != nil)

        service.invalidateJWT()

        #expect((try storage.load(.jwt)) == nil)       // transient slot evicted
        #expect((try storage.load(.payload)) != nil)   // durable payload survives
    }

    @Test func currentJWTReusesCachedTokenWhenFresh() async throws {
        let session = StubRequestSession()
        let storage = InMemoryTokenStorage()
        try storage.save("session-abc", for: .sessionToken)
        let service = AuthService(configuration: Self.config, storage: storage, session: session)

        session.enqueue(StubRequestSession.Stub(
            statusCode: 200,
            body: Data(#"{"token":"\#(Fixtures.jwt(expiresIn: 3600))"}"#.utf8)
        ))
        await service.restoreSession()

        // No more stubs queued — second currentJWT() must reuse cache.
        _ = try await service.currentJWT()
        _ = try await service.currentJWT()
        // restoreSession used 1 request; the cache must have suppressed any further.
        #expect(session.recordedRequests.count == 1)
    }

    // MARK: - Connectivity outcome hook (issue #71)

    @Test func refreshTransportThrowReportsOfflineOutcome() async throws {
        // A `/auth/token` exchange that fails on the transport (no network /
        // captive portal) must feed the connectivity hook a `false` — the gap
        // #71 closes, since this throw happens inside currentJWT()/refreshJWT(),
        // before any APIClient.fire() could report it. Driven via restoreSession
        // so the refresh leg is the *only* transport call (no sign-in handshake
        // ahead of it to pollute the recorder).
        let session = StubRequestSession()
        let storage = InMemoryTokenStorage()
        try storage.save("session-abc", for: .sessionToken)
        let recorder = OutcomeRecorder()
        let service = AuthService(
            configuration: Self.config,
            storage: storage,
            session: session,
            onOutcome: { recorder.record($0) }
        )

        session.enqueue(failure: URLError(.notConnectedToInternet))
        await service.restoreSession()

        #expect(recorder.values == [false])
    }

    @Test func refreshUnauthorizedReportsOnlineOutcome() async throws {
        // A `401` on `/auth/token` is terminal for the *session* (the bearer was
        // rejected), but the server still answered — so for *connectivity* it's a
        // positive outcome: we reached the backend. The hook must report `true`,
        // mirroring APIClient.fire()'s "any HTTP status = reachable" rule, even as
        // restoreSession() clears the dead session and lands on .signedOut.
        let session = StubRequestSession()
        let storage = InMemoryTokenStorage()
        try storage.save("session-abc", for: .sessionToken)
        let recorder = OutcomeRecorder()
        let service = AuthService(
            configuration: Self.config,
            storage: storage,
            session: session,
            onOutcome: { recorder.record($0) }
        )

        session.enqueue(StubRequestSession.Stub(statusCode: 401))
        await service.restoreSession()

        #expect(recorder.values == [true])
        #expect(service.state == .signedOut)   // terminal arm still fired
    }

    @Test func refreshSuccessReportsOnlineOutcome() async throws {
        // The happy path: a `200` JWT exchange is a confirmed server contact, so
        // the hook reports `true` (and the DJ is signed in).
        let session = StubRequestSession()
        let storage = InMemoryTokenStorage()
        try storage.save("session-abc", for: .sessionToken)
        let recorder = OutcomeRecorder()
        let service = AuthService(
            configuration: Self.config,
            storage: storage,
            session: session,
            onOutcome: { recorder.record($0) }
        )

        session.enqueue(StubRequestSession.Stub(
            statusCode: 200,
            body: Data(#"{"token":"\#(Fixtures.jwt())"}"#.utf8)
        ))
        await service.restoreSession()

        #expect(recorder.values == [true])
        #expect(service.isSignedIn)
    }

    @Test func signInTransportThrowReportsOfflineOutcome() async throws {
        // Issue #71 wraps the transport generally, so the sign-in leg
        // (`/auth/sign-in/username`) feeds connectivity too: a foreground sign-in
        // that can't reach the server is just as much an offline signal as a
        // refresh failure. The thrown URLError reports `false`; the auth state
        // machine is unchanged (terminal leg-1 failure -> .signedOut, no trace).
        let session = StubRequestSession()
        let storage = InMemoryTokenStorage()
        let recorder = OutcomeRecorder()
        let service = AuthService(
            configuration: Self.config,
            storage: storage,
            session: session,
            onOutcome: { recorder.record($0) }
        )

        session.enqueue(failure: URLError(.notConnectedToInternet))
        await service.signIn(identifier: "dj", password: "pw")

        #expect(recorder.values == [false])
        #expect(service.state == .signedOut)
    }

    @Test func signOutTransportReportsOnlineOutcome() async throws {
        // The best-effort `/auth/sign-out` POST is also routed through the hook:
        // a server that answered the sign-out is reachable, so it reports `true`.
        // (The sign-out outcome is the *second* value — the first is the
        // restoreSession success that put us in a signed-in state to sign out of.)
        let session = StubRequestSession()
        let storage = InMemoryTokenStorage()
        try storage.save("session-abc", for: .sessionToken)
        let recorder = OutcomeRecorder()
        let service = AuthService(
            configuration: Self.config,
            storage: storage,
            session: session,
            onOutcome: { recorder.record($0) }
        )

        session.enqueue(StubRequestSession.Stub(
            statusCode: 200,
            body: Data(#"{"token":"\#(Fixtures.jwt())"}"#.utf8)
        ))
        await service.restoreSession()
        #expect(recorder.values == [true])   // restore leg

        session.enqueue(StubRequestSession.Stub(statusCode: 200))
        await service.signOut()

        #expect(recorder.values == [true, true])   // + sign-out leg
        #expect(service.state == .signedOut)
    }

    @Test(arguments: [URLError(.cancelled) as any Error & Sendable, CancellationError()])
    func refreshCancellationDoesNotReportAnOutcome(cancellation: any Error & Sendable) async throws {
        // A cancelled Task is a deliberate abandonment, not "offline": the auth
        // transport is reachable from cancellable call sites — the search debounce
        // (`searchTask.cancel()`) and the background-refresh expiration handler
        // (`work.cancel()`) both cancel a JWT-refresh leg in flight — so it must
        // NOT be mistaken for evidence the server is unreachable. Covers both
        // forms `send()` treats as a cancellation: URLSession's
        // `URLError.cancelled` and a raw `CancellationError`.
        let session = StubRequestSession()
        let storage = InMemoryTokenStorage()
        try storage.save("session-abc", for: .sessionToken)
        let recorder = OutcomeRecorder()
        let service = AuthService(
            configuration: Self.config,
            storage: storage,
            session: session,
            onOutcome: { recorder.record($0) }
        )

        session.enqueue(failure: cancellation)
        await service.restoreSession()

        #expect(recorder.values == [])   // no connectivity signal
        // The error still propagated to restoreSession's transient arm (it was
        // rethrown, not swallowed): with no grace anchors persisted, that arm
        // lands `.signedOut`.
        #expect(service.state == .signedOut)
    }
}
