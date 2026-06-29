//
//  QRDeviceVerifyTests.swift
//  WXYCAPITests
//
//  Pins the wire shape and error mapping for POST /auth/device/approve and
//  POST /auth/device/deny (ADR 0002 / api.yaml issue #195): each hits the auth
//  base URL with a camelCase userCode body + Bearer JWT, a 2xx returns `success`,
//  and each documented error code maps to its typed ``QRSignInError`` case.
//
//  Created by Jake on 6/28/26.
//  Copyright © 2026 WXYC. All rights reserved.
//

import Foundation
import Testing
@testable import WXYCAPI

@Suite("QR device approve/deny", .serialized)
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

    @Test func approveSendsCamelCaseUserCodeBody() async throws {
        let (client, _, session) = try await Self.makeSignedInClient()
        session.enqueue(StubRequestSession.Stub(
            statusCode: 200,
            body: Data(#"{"success":true}"#.utf8)
        ))

        try await client.approveDevice(userCode: "DXFP-92QR")

        let request = try #require(session.recordedRequests.last)
        #expect(request.httpMethod == "POST")
        #expect(request.url?.absoluteString == "http://localhost:8082/auth/device/approve")
        #expect(request.value(forHTTPHeaderField: "Authorization")?.hasPrefix("Bearer ") == true)
        #expect(request.value(forHTTPHeaderField: "Content-Type") == "application/json")
        let body = try #require(request.httpBody)
        let decoded = try JSONSerialization.jsonObject(with: body) as? [String: String]
        // Casing trap: the api.yaml contract is camelCase here even though the
        // verify-lookup at GET /auth/device uses snake_case `user_code`.
        #expect(decoded?["userCode"] == "DXFP-92QR")
        #expect(decoded?["user_code"] == nil)
    }

    @Test func denySendsToDenyPath() async throws {
        let (client, _, session) = try await Self.makeSignedInClient()
        session.enqueue(StubRequestSession.Stub(
            statusCode: 200,
            body: Data(#"{"success":true}"#.utf8)
        ))

        try await client.denyDevice(userCode: "DXFP-92QR")

        let request = try #require(session.recordedRequests.last)
        #expect(request.url?.path == "/auth/device/deny")
        let body = try #require(request.httpBody)
        let decoded = try JSONSerialization.jsonObject(with: body) as? [String: String]
        #expect(decoded?["userCode"] == "DXFP-92QR")
    }

    @Test func accessDeniedFrom403MapsToTypedError() async throws {
        let (client, _, session) = try await Self.makeSignedInClient()
        session.enqueue(StubRequestSession.Stub(
            statusCode: 403,
            headers: ["Content-Type": "application/json"],
            body: Data(#"{"error":"access_denied","error_description":"role not permitted"}"#.utf8)
        ))

        do {
            try await client.approveDevice(userCode: "DXFP-92QR")
            Issue.record("expected QRSignInError.accessDenied")
        } catch let error as QRSignInError {
            #expect(error == .accessDenied(reason: "role not permitted"))
        }
    }

    @Test func expiredTokenFrom400MapsToExpiredCode() async throws {
        let (client, _, session) = try await Self.makeSignedInClient()
        session.enqueue(StubRequestSession.Stub(
            statusCode: 400,
            headers: ["Content-Type": "application/json"],
            body: Data(#"{"error":"expired_token","error_description":"code expired"}"#.utf8)
        ))

        do {
            try await client.approveDevice(userCode: "DXFP-92QR")
            Issue.record("expected QRSignInError.expiredCode")
        } catch let error as QRSignInError {
            #expect(error == .expiredCode(reason: "code expired"))
        }
    }

    @Test func invalidRequestFrom400MapsToInvalidCode() async throws {
        let (client, _, session) = try await Self.makeSignedInClient()
        session.enqueue(StubRequestSession.Stub(
            statusCode: 400,
            headers: ["Content-Type": "application/json"],
            body: Data(#"{"error":"invalid_request","error_description":"unknown code"}"#.utf8)
        ))

        do {
            try await client.approveDevice(userCode: "DXFP-92QR")
            Issue.record("expected QRSignInError.invalidCode")
        } catch let error as QRSignInError {
            #expect(error == .invalidCode(reason: "unknown code"))
        }
    }

    @Test func unauthorizedBodyMapsToNotSignedIn() async throws {
        let (client, _, session) = try await Self.makeSignedInClient()
        // 401 carrying the typed `unauthorized` envelope. The transport's
        // own 401-retry path is skipped because the body provides a typed
        // code — the action methods treat the typed envelope as authoritative.
        // Stub two responses: the 401 attempt + the post-refresh retry (also a
        // 401, because no session can recover this), plus the JWT refresh in
        // between that the transport triggers on the first 401.
        session.enqueue(StubRequestSession.Stub(
            statusCode: 401,
            headers: ["Content-Type": "application/json"],
            body: Data(#"{"error":"unauthorized","error_description":"no session"}"#.utf8)
        ))
        // JWT refresh during retry.
        session.enqueue(StubRequestSession.Stub(
            statusCode: 200,
            body: Data(#"{"token":"\#(Fixtures.jwt())"}"#.utf8)
        ))
        // Retry — still 401 with the typed envelope.
        session.enqueue(StubRequestSession.Stub(
            statusCode: 401,
            headers: ["Content-Type": "application/json"],
            body: Data(#"{"error":"unauthorized","error_description":"no session"}"#.utf8)
        ))

        do {
            try await client.approveDevice(userCode: "DXFP-92QR")
            Issue.record("expected QRSignInError.notSignedIn")
        } catch let error as QRSignInError {
            #expect(error == .notSignedIn)
        }
    }

    @Test func serverErrorWrapsAsTransport() async throws {
        let (client, _, session) = try await Self.makeSignedInClient()
        session.enqueue(StubRequestSession.Stub(statusCode: 500, body: Data()))

        do {
            try await client.approveDevice(userCode: "DXFP-92QR")
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
            try await client.approveDevice(userCode: "DXFP-92QR")
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
