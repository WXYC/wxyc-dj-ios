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

    @Test func restoreSessionWithTransientServerErrorEntersPending() async throws {
        // Cold launch with a stored token, /auth/token returns 5xx (server down,
        // not "session expired"). Issue #53: the returning DJ enters the pending
        // window (.signedIn(payload: nil)) rather than being dumped to a login
        // screen — strictly better, especially offline, since MainView still
        // browses the on-device catalog clone. The persisted session token stays
        // so the JWT can be re-minted lazily, which the follow-on proves.
        let session = StubRequestSession()
        let storage = InMemoryTokenStorage()
        try storage.save("session-stored", for: .sessionToken)
        let service = AuthService(configuration: Self.config, storage: storage, session: session)

        session.enqueue(StubRequestSession.Stub(statusCode: 503, body: Data()))

        await service.restoreSession()

        #expect(service.state == .signedIn(payload: nil))
        // Keychain must still hold the token for the lazy retry.
        #expect(try storage.load(.sessionToken) == "session-stored")

        // Follow-on: the lazy currentJWT() re-mints the JWT once the server
        // recovers, and the DJ stays signed in.
        session.enqueue(StubRequestSession.Stub(
            statusCode: 200,
            body: Data(#"{"token":"\#(Fixtures.jwt())"}"#.utf8)
        ))
        let token = try await service.currentJWT()
        #expect(!token.isEmpty)
        #expect(service.isSignedIn)
    }

    @Test func restoreSessionWith401ClearsStoredToken() async throws {
        // Cold launch with a stored token that the server rejects (401): the
        // session is dead. Issue #53 makes this terminal arm clear the token —
        // previously restoreSession's catch-all kept it, so a revoked session
        // lingered in the Keychain and 401'd on every launch forever.
        let session = StubRequestSession()
        let storage = InMemoryTokenStorage()
        try storage.save("session-revoked", for: .sessionToken)
        let service = AuthService(configuration: Self.config, storage: storage, session: session)

        session.enqueue(StubRequestSession.Stub(statusCode: 401, body: Data()))

        await service.restoreSession()

        #expect(service.state == .signedOut)
        #expect(try storage.load(.sessionToken) == nil)
        #expect(try storage.load(.jwt) == nil)
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
