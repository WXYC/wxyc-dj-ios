//
//  SignedInClient.swift
//  WXYCDJToolTests
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
        let storage = InMemoryTokenStorage()
        try storage.save("session-abc", for: .sessionToken)
        let auth = AuthService(configuration: configuration, storage: storage, session: session)
        session.enqueue(StubRequestSession.Stub(
            statusCode: 200,
            body: Data(#"{"token":"\#(Fixtures.jwt())"}"#.utf8)
        ))
        await auth.restoreSession()
        let client = APIClient(configuration: configuration, session: session, authService: auth)
        return (client, session)
    }
}
