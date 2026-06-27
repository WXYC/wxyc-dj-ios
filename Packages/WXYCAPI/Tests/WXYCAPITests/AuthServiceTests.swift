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
import Testing
@testable import WXYCAPI

@Suite("AuthService", .serialized)
@MainActor
struct AuthServiceTests {
    private static let config = WXYCAPIConfiguration.localDevelopment

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

        await service.signIn(username: "dj", password: "pw")

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
        await service.signIn(username: "dj", password: "pw")
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

        await service.signIn(username: "dj", password: "wrong")

        #expect(service.state == .signedOut)
        #expect(service.lastError == .invalidCredentials)
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

        await service.signIn(username: "dj", password: "pw")

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

        await service.signIn(username: "dj", password: "pw")

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

        await service.signIn(username: "dj", password: "pw")

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

        await service.signIn(username: "dj", password: "pw")

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
        await service.signIn(username: "dj", password: "pw")
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
        await service.signIn(username: "dj", password: "pw")
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
        await service.signIn(username: "dj", password: "pw")
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
        await service.signIn(username: "dj", password: "pw")
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
        await service.signIn(username: "dj", password: "pw")
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
        await first.signIn(username: "dj", password: "pw")
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
        await first.signIn(username: "dj", password: "pw")

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
        await service.signIn(username: "dj", password: "pw")

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
        await service.signIn(username: "dj-a", password: "pw")
        #expect((try storage.load(.payload)) != nil)
        #expect((try storage.load(.lastValidatedAt)) != nil)

        // DJ B: leg 1 establishes a new session, leg 2 (the JWT exchange) fails
        // transiently — only one stub, so the /auth/token call throws.
        session.enqueue(StubRequestSession.Stub(
            statusCode: 200,
            headers: ["set-auth-token": "session-B"],
            body: Data("{}".utf8)
        ))
        await service.signIn(username: "dj-b", password: "pw")

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
        await service.signIn(username: "dj", password: "pw")
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
}
