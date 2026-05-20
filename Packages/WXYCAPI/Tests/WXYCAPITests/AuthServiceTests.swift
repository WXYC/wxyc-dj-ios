//
//  AuthServiceTests.swift
//  WXYCAPITests
//
//  Drives AuthService against a stub network: sign-in success grabs the
//  session token from the set-auth-token header, the JWT exchange decodes
//  claims, 401 on sign-in maps to invalidCredentials, and restoreSession
//  brings a stored token back to .signedIn.
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
        #expect(payload.role == "dj")
        #expect(try storage.load(.sessionToken) == "session-abc")
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
            #expect(payload.email == "juana@wxyc.org")
        } else {
            Issue.record("expected signedIn, got \(service.state)")
        }
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
