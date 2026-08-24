//
//  SignedInClient.swift
//  WXYCDJTests
//
//  Test helper: stand up an APIClient already pinned to a fresh JWT so view-
//  model tests can skip the sign-in dance and stub the endpoints they care
//  about. Mirrors makeSignedInClient() in WXYCAPITests/APIClientTests.swift.
//
//  Created by Jake on 5/20/26.
//  Copyright © 2026 WXYC. All rights reserved.
//

import Foundation
@testable import WXYCAPI

enum SignedInClient {
    static let configuration = WXYCAPIConfiguration.localDevelopment

    @MainActor
    static func make() async throws -> (APIClient, StubRequestSession) {
        let session = StubRequestSession()
        let auth = try await makeAuth(session: session)
        let client = APIClient(configuration: configuration, session: session, authService: auth)
        return (client, session)
    }

    /// An `APIClient` whose **data** requests go through a `BlockingRequestSession`
    /// the caller controls, while the JWT exchange behind it runs on a separate
    /// stub and is already settled.
    ///
    /// `AuthService` and `APIClient` take independent `session` parameters, which
    /// is what makes this possible without a request-routing stub: the auth leg
    /// finishes on the stub before the client is built, and `currentJWT()` is
    /// cached thereafter, so every request that reaches `blocking` is a real API
    /// call the test wants to hold open.
    @MainActor
    static func makeBlocking(responseBody: Data) async throws -> (APIClient, BlockingRequestSession) {
        let blocking = BlockingRequestSession(body: responseBody)
        let auth = try await makeAuth(session: StubRequestSession())
        let client = APIClient(configuration: configuration, session: blocking, authService: auth)
        return (client, blocking)
    }

    @MainActor
    private static func makeAuth(session: StubRequestSession) async throws -> AuthService {
        let storage = InMemoryTokenStorage()
        try storage.save("session-abc", for: .sessionToken)
        let auth = AuthService(configuration: configuration, storage: storage, session: session)
        session.enqueue(StubRequestSession.Stub(
            statusCode: 200,
            body: Data(#"{"token":"\#(Fixtures.jwt())"}"#.utf8)
        ))
        await auth.restoreSession()
        return auth
    }
}
