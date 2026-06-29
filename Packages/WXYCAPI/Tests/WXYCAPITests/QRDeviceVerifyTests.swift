//
//  QRDeviceVerifyTests.swift
//  WXYCAPITests
//
//  Pins the wire shape and error mapping for POST /auth/device/verify (ADR
//  0002): the request hits the auth base URL with a Bearer JWT and a JSON
//  body, a 400 with an `error` field decodes to ``QRSignInError/accessDenied``,
//  a 401 retries once after a JWT refresh, and other non-2xx surfaces wrap as
//  ``QRSignInError/transport``.
//
//  Created by Jake on 6/28/26.
//  Copyright © 2026 WXYC. All rights reserved.
//

import Foundation
import Testing
@testable import WXYCAPI

@Suite("QR device verify", .serialized)
@MainActor
struct QRDeviceVerifyTests {
    private static let config = WXYCAPIConfiguration.localDevelopment

    private static func makeSignedInClient() async throws -> (APIClient, AuthService, StubRequestSession) {
        let session = StubRequestSession()
        let storage = InMemoryTokenStorage()
        try storage.save("session-abc", for: .sessionToken)
        let auth = AuthService(configuration: config, storage: storage, session: session)
        session.enqueue(StubRequestSession.Stub(
            statusCode: 200,
            body: Data(#"{"token":"\#(Fixtures.jwt())"}"#.utf8)
        ))
        await auth.restoreSession()
        let client = APIClient(configuration: config, session: session, authService: auth)
        return (client, auth, session)
    }

    @Test func approveSendsExpectedRequest() async throws {
        let (client, _, session) = try await Self.makeSignedInClient()
        session.enqueue(StubRequestSession.Stub(statusCode: 200, body: Data()))

        try await client.verifyDeviceCode(userCode: "DXFP-92QR", approve: true)

        let request = try #require(session.recordedRequests.last)
        #expect(request.httpMethod == "POST")
        #expect(request.url?.absoluteString == "http://localhost:8082/auth/device/verify")
        #expect(request.value(forHTTPHeaderField: "Authorization")?.hasPrefix("Bearer ") == true)
        #expect(request.value(forHTTPHeaderField: "Content-Type") == "application/json")
        let body = try #require(request.httpBody)
        let decoded = try JSONSerialization.jsonObject(with: body) as? [String: String]
        #expect(decoded?["user_code"] == "DXFP-92QR")
        #expect(decoded?["action"] == "approve")
    }

    @Test func denySendsActionDeny() async throws {
        let (client, _, session) = try await Self.makeSignedInClient()
        session.enqueue(StubRequestSession.Stub(statusCode: 200, body: Data()))

        try await client.verifyDeviceCode(userCode: "DXFP-92QR", approve: false)

        let body = try #require(session.recordedRequests.last?.httpBody)
        let decoded = try JSONSerialization.jsonObject(with: body) as? [String: String]
        #expect(decoded?["action"] == "deny")
    }

    @Test func accessDeniedMapsToTypedError() async throws {
        let (client, _, session) = try await Self.makeSignedInClient()
        session.enqueue(StubRequestSession.Stub(
            statusCode: 400,
            headers: ["Content-Type": "application/json"],
            body: Data(#"{"error":"access_denied","error_description":"role not permitted"}"#.utf8)
        ))

        do {
            try await client.verifyDeviceCode(userCode: "DXFP-92QR", approve: true)
            Issue.record("expected QRSignInError.accessDenied")
        } catch let error as QRSignInError {
            #expect(error == .accessDenied(reason: "role not permitted"))
        }
    }

    @Test func expiredTokenMapsToAccessDenied() async throws {
        let (client, _, session) = try await Self.makeSignedInClient()
        session.enqueue(StubRequestSession.Stub(
            statusCode: 400,
            headers: ["Content-Type": "application/json"],
            body: Data(#"{"error":"expired_token","error_description":"code expired"}"#.utf8)
        ))

        do {
            try await client.verifyDeviceCode(userCode: "DXFP-92QR", approve: true)
            Issue.record("expected QRSignInError.accessDenied")
        } catch let error as QRSignInError {
            #expect(error == .accessDenied(reason: "code expired"))
        }
    }

    @Test func unauthorizedRetriesOnceAfterJWTRefresh() async throws {
        let (client, _, session) = try await Self.makeSignedInClient()
        // First verify attempt — 401.
        session.enqueue(StubRequestSession.Stub(statusCode: 401, body: Data()))
        // The 401 triggers AuthService.invalidateJWT(); the next currentJWT()
        // call refreshes against /auth/token before retrying the verify.
        session.enqueue(StubRequestSession.Stub(
            statusCode: 200,
            body: Data(#"{"token":"\#(Fixtures.jwt())"}"#.utf8)
        ))
        // Retry — 200.
        session.enqueue(StubRequestSession.Stub(statusCode: 200, body: Data()))

        try await client.verifyDeviceCode(userCode: "DXFP-92QR", approve: true)

        let recorded = session.recordedRequests
        // Initial /auth/token (restoreSession) + verify(401) + /auth/token (refresh) + verify(200) = 4
        #expect(recorded.count == 4)
        #expect(recorded[1].url?.path == "/auth/device/verify")
        #expect(recorded[2].url?.path == "/auth/token")
        #expect(recorded[3].url?.path == "/auth/device/verify")
    }

    @Test func serverErrorWrapsAsTransport() async throws {
        let (client, _, session) = try await Self.makeSignedInClient()
        session.enqueue(StubRequestSession.Stub(statusCode: 500, body: Data()))

        do {
            try await client.verifyDeviceCode(userCode: "DXFP-92QR", approve: true)
            Issue.record("expected QRSignInError.transport")
        } catch let error as QRSignInError {
            if case .transport(let inner) = error {
                if case .http(let status, _) = inner {
                    #expect(status == 500)
                } else {
                    Issue.record("expected APIError.http; got \(inner)")
                }
            } else {
                Issue.record("expected .transport; got \(error)")
            }
        }
    }

    @Test func unreachableServerWrapsAsTransportNetwork() async throws {
        let (client, _, session) = try await Self.makeSignedInClient()
        session.enqueue(failure: URLError(.notConnectedToInternet))

        do {
            try await client.verifyDeviceCode(userCode: "DXFP-92QR", approve: true)
            Issue.record("expected QRSignInError.transport")
        } catch let error as QRSignInError {
            if case .transport(let inner) = error {
                if case .network = inner { /* expected */ }
                else { Issue.record("expected APIError.network; got \(inner)") }
            } else {
                Issue.record("expected .transport; got \(error)")
            }
        }
    }
}
