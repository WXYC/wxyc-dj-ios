//
//  QRSignInViewModelTests.swift
//  WXYCDJTests
//
//  Exercises the QRSignInViewModel state machine end-to-end with a stubbed
//  RequestSession + biometric authenticator: happy path, role gate, server
//  denial, biometric cancel, reject, malformed payload, unsigned-in startup.
//
//  Created by Jake on 6/28/26.
//  Copyright © 2026 WXYC. All rights reserved.
//

import Foundation
import Testing
@testable import WXYCDJ
@testable import WXYCAPI

@Suite("QR sign-in view model", .serialized)
@MainActor
struct QRSignInViewModelTests {
    private static let config = WXYCAPIConfiguration.localDevelopment
    private static let payload = "https://dj.wxyc.org/auth/device?user_code=DXFP-92QR"

    /// Stand up a signed-in `AuthService` + `APIClient` over a fresh
    /// `StubRequestSession`. `role` defaults to `dj`; the role-gate test
    /// passes `member`.
    private static func makeSignedIn(role: String = "dj") async throws -> (APIClient, AuthService, StubRequestSession) {
        let session = StubRequestSession()
        let storage = InMemoryTokenStorage()
        try storage.save("session-abc", for: .sessionToken)
        let auth = AuthService(configuration: config, storage: storage, session: session)
        session.enqueue(StubRequestSession.Stub(
            statusCode: 200,
            body: Data(#"{"token":"\#(Fixtures.jwt(role: role))"}"#.utf8)
        ))
        await auth.restoreSession()
        let client = APIClient(configuration: config, session: session, authService: auth)
        return (client, auth, session)
    }

    @Test func happyPathDJ() async throws {
        let (api, auth, session) = try await Self.makeSignedIn()
        let biometrics = StubBiometricAuthenticator()
        biometrics.enqueue(.success(true))
        // /auth/device/approve gets a 200 with the api.yaml { success } body.
        session.enqueue(StubRequestSession.Stub(
            statusCode: 200,
            body: Data(#"{"success":true}"#.utf8)
        ))

        let vm = QRSignInViewModel(api: api, authService: auth, biometrics: biometrics)
        #expect(vm.state == .scanning)

        vm.handleScannedPayload(Self.payload)
        #expect(vm.state == .approving(userCode: "DXFP-92QR"))

        await vm.approve()
        #expect(vm.state == .succeeded)
        #expect(biometrics.callCount == 1)
        #expect(session.recordedRequests.last?.url?.path == "/auth/device/approve")
    }

    @Test func roleGatedMember() async throws {
        let (api, auth, _) = try await Self.makeSignedIn(role: "member")
        let biometrics = StubBiometricAuthenticator()

        let vm = QRSignInViewModel(api: api, authService: auth, biometrics: biometrics)
        vm.handleScannedPayload(Self.payload)

        #expect(vm.state == .roleGated(role: "member"))
        // No biometric prompt, no verify call attempted.
        #expect(biometrics.callCount == 0)
    }

    @Test func serverDenialSurfacesAsError() async throws {
        let (api, auth, session) = try await Self.makeSignedIn()
        let biometrics = StubBiometricAuthenticator()
        biometrics.enqueue(.success(true))
        // Approve returns 403 access_denied — the auth-service role gate
        // catches a freshly-downgraded role that passed the client-side gate.
        session.enqueue(StubRequestSession.Stub(
            statusCode: 403,
            headers: ["Content-Type": "application/json"],
            body: Data(#"{"error":"access_denied","error_description":"role lost"}"#.utf8)
        ))

        let vm = QRSignInViewModel(api: api, authService: auth, biometrics: biometrics)
        vm.handleScannedPayload(Self.payload)
        await vm.approve()

        if case .error(let message) = vm.state {
            #expect(message == "role lost")
        } else {
            Issue.record("expected .error; got \(vm.state)")
        }
    }

    @Test func biometricCancelReturnsToApproving() async throws {
        let (api, auth, session) = try await Self.makeSignedIn()
        let biometrics = StubBiometricAuthenticator()
        biometrics.enqueue(.success(false))

        let vm = QRSignInViewModel(api: api, authService: auth, biometrics: biometrics)
        vm.handleScannedPayload(Self.payload)
        await vm.approve()

        #expect(vm.state == .approving(userCode: "DXFP-92QR"))
        // No approve/deny was issued — the recorded list contains only the
        // restoreSession JWT refresh.
        #expect(session.recordedRequests.allSatisfy { request in
            let path = request.url?.path ?? ""
            return path != "/auth/device/approve" && path != "/auth/device/deny"
        })
    }

    @Test func rejectSendsDenyAction() async throws {
        let (api, auth, session) = try await Self.makeSignedIn()
        let biometrics = StubBiometricAuthenticator()
        // /auth/device/deny returns 200 with the api.yaml { success } body.
        session.enqueue(StubRequestSession.Stub(
            statusCode: 200,
            body: Data(#"{"success":true}"#.utf8)
        ))

        let vm = QRSignInViewModel(api: api, authService: auth, biometrics: biometrics)
        vm.handleScannedPayload(Self.payload)
        await vm.reject()

        #expect(vm.state == .rejected)
        let denyRequest = try #require(session.recordedRequests.last)
        #expect(denyRequest.url?.path == "/auth/device/deny")
        let body = try #require(denyRequest.httpBody)
        let decoded = try JSONSerialization.jsonObject(with: body) as? [String: String]
        #expect(decoded?["userCode"] == "DXFP-92QR")
        // No biometric on reject.
        #expect(biometrics.callCount == 0)
    }

    @Test func invalidPayloadSurfacesError() async throws {
        let (api, auth, _) = try await Self.makeSignedIn()
        let biometrics = StubBiometricAuthenticator()

        let vm = QRSignInViewModel(api: api, authService: auth, biometrics: biometrics)
        vm.handleScannedPayload("https://evil.example/?user_code=ZZZZ")

        if case .error = vm.state { /* expected */ }
        else { Issue.record("expected .error; got \(vm.state)") }
    }

    @Test func notSignedInStartsInError() async throws {
        // Build an AuthService that has never restored. Its state is
        // .signedOut after a fresh restore against an empty Keychain.
        let session = StubRequestSession()
        let storage = InMemoryTokenStorage()
        let auth = AuthService(configuration: Self.config, storage: storage, session: session)
        await auth.restoreSession()
        let client = APIClient(configuration: Self.config, session: session, authService: auth)
        let biometrics = StubBiometricAuthenticator()

        let vm = QRSignInViewModel(api: client, authService: auth, biometrics: biometrics)
        if case .error = vm.state { /* expected */ }
        else { Issue.record("expected .error; got \(vm.state)") }
    }

    @Test func duplicateScansIgnoredAfterFirstAccept() async throws {
        let (api, auth, _) = try await Self.makeSignedIn()
        let biometrics = StubBiometricAuthenticator()

        let vm = QRSignInViewModel(api: api, authService: auth, biometrics: biometrics)
        vm.handleScannedPayload(Self.payload)
        // A second frame containing a different code must NOT roll the
        // approval forward — the AVFoundation delegate keeps firing.
        vm.handleScannedPayload("https://dj.wxyc.org/auth/device?user_code=OTHER-CODE")
        #expect(vm.state == .approving(userCode: "DXFP-92QR"))
    }
}
