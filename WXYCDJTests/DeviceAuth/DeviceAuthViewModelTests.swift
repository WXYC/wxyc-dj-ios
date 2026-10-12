//
//  DeviceAuthViewModelTests.swift
//  WXYCDJ
//
//  Unit tests for DeviceAuthViewModel approval, rejection, and role authorization logic.
//
//  Created by Meira Volk on 08/19/26.
//  Copyright © 2026 WXYC. All rights reserved.
//

import Foundation
import Testing
@testable import WXYCAPI
@testable import WXYCDJ

@Suite("DeviceAuthViewModel", .serialized)
@MainActor
struct DeviceAuthViewModelTests {
    private static func makeViewModel(_ auth: AuthService) -> DeviceAuthViewModel {
        return DeviceAuthViewModel(auth: auth)
    }
    
    private static func renderedSheet(_ viewModel: DeviceAuthViewModel, userCode: String?) -> DeviceAuthViewModel.SheetContent {
        DeviceAuthViewModel.sheetContent(
            workflowState: viewModel.workflowState,
            userCode: userCode,
            approveError: viewModel.approveError,
            fallbackMessage: "Unknown code"
        )
    }

    private static func makeAuth(session: StubRequestSession, role: String? = "dj") async throws -> AuthService {
        let storage = InMemoryTokenStorage()
        try storage.save("session-abc", for: .sessionToken)
        let auth = AuthService(configuration: WXYCAPIConfiguration.localDevelopment, storage: storage, session: session)
        session.enqueue(StubRequestSession.Stub(
            statusCode: 200,
            body: Data(#"{"token":"\#(Fixtures.jwt(role: role))"}"#.utf8)
        ))
        await auth.restoreSession()
        return auth
    }

    @Test func approveSuccess() async throws {
        let session = StubRequestSession()
        let auth = try await DeviceAuthViewModelTests.makeAuth(session: session)
        let viewModel = Self.makeViewModel(auth)
        let baseline = session.recordedRequests.count
        
        let userCode = "ABCD-1234"
        session.enqueue(StubRequestSession.Stub(statusCode: 200, body: Data(#"{"success": true}"#.utf8)))
        
        let message = await viewModel.approve(userCode: userCode)
        
        #expect(message == "Approved — browser session started")
        #expect(session.recordedRequests.count == baseline + 1)
        #expect(viewModel.approveError == nil)
        #expect(Self.renderedSheet(viewModel, userCode: userCode) == .approved(toast: "Approved — browser session started"))
    }
    
    // MARK: - Member role gate

    /// `nil` = a decoded token with no role claim, which may be a transient
    /// membership-lookup failure at mint time — the server decides.
    @Test(arguments: ["dj", "musicDirector", "stationManager", nil] as [String?])
    func nonMemberRolesAreNotBlocked(role: String?) async throws {
        let session = StubRequestSession()
        let auth = try await Self.makeAuth(session: session, role: role)
        #expect(Self.makeViewModel(auth).isMember == false)
    }

    @Test func memberRoleIsBlocked() async throws {
        let session = StubRequestSession()
        let auth = try await Self.makeAuth(session: session, role: "member")
        #expect(Self.makeViewModel(auth).isMember == true)
    }

    /// Issue-#53 pending-JWT window: role unknown, so the phone doesn't
    /// guess — the server's 403 decides.
    @Test func pendingJWTWindowIsNotAMember() async throws {
        // A sign-in whose JWT leg fails transiently is what enters the window
        // (a cold-launch restore with no grace anchor signs out instead).
        let session = StubRequestSession()
        let auth = AuthService(configuration: WXYCAPIConfiguration.localDevelopment, storage: InMemoryTokenStorage(), session: session)
        session.enqueue(StubRequestSession.Stub(statusCode: 200, headers: ["set-auth-token": "session-abc"]))
        session.enqueue(StubRequestSession.Stub(statusCode: 503, body: Data(#"{"error":"boom"}"#.utf8)))
        await auth.signIn(identifier: "juana", password: "hunter2")
        try #require(auth.state == .signedIn(payload: nil))

        #expect(Self.makeViewModel(auth).isMember == false)
    }

    /// Catches: a member's scan reaching `GET /auth/device`, which would claim
    /// the code and lock the DJ it was meant for out of it.
    @Test func memberScanSendsNothingAndShowsDenialCard() async throws {
        let session = StubRequestSession()
        let auth = try await Self.makeAuth(session: session, role: "member")
        let viewModel = Self.makeViewModel(auth)
        let baseline = session.recordedRequests.count

        let userCode = viewModel.processCode(scannedCode: "https://dj.wxyc.org/device-auth?user_code=ABCD-1234")
        await Task.yield()

        #expect(userCode == nil)
        #expect(viewModel.workflowState == .memberBlocked)
        #expect(Self.renderedSheet(viewModel, userCode: userCode) == .memberDenied)
        #expect(session.recordedRequests.count == baseline)
    }

    @Test func approveMemberRoleGateBlockedLocally() async throws {
        let session = StubRequestSession()
        let auth = try await Self.makeAuth(session: session, role: "member")
        let viewModel = Self.makeViewModel(auth)
        let baseline = session.recordedRequests.count

        let message = await viewModel.approve(userCode: "ABCD-1234")

        #expect(message == DeviceAuthViewModel.memberBlockedMessage)
        #expect(viewModel.approveError == DeviceAuthViewModel.memberBlockedMessage)
        #expect(session.recordedRequests.count == baseline)
    }

    /// Deny is terminal server-side; a member must never send it.
    @Test func denyMemberRoleGateBlockedLocally() async throws {
        let session = StubRequestSession()
        let auth = try await Self.makeAuth(session: session, role: "member")
        let viewModel = Self.makeViewModel(auth)
        let baseline = session.recordedRequests.count

        let message = await viewModel.deny(userCode: "ABCD-1234")

        #expect(message == DeviceAuthViewModel.memberBlockedMessage)
        #expect(session.recordedRequests.count == baseline)
    }

    @Test func memberBlockedStateRendersDenialCardEvenWithUserCode() {
        let content = DeviceAuthViewModel.sheetContent(
            workflowState: .memberBlocked,
            userCode: "ABCD-1234",
            approveError: nil,
            fallbackMessage: "Unknown code"
        )
        #expect(content == .memberDenied)
    }


    @Test func approveAccessDeniedError403() async throws {
        let session = StubRequestSession()
        let auth = try await DeviceAuthViewModelTests.makeAuth(session: session)
        let viewModel = Self.makeViewModel(auth)
        let baseline = session.recordedRequests.count
        
        session.enqueue(StubRequestSession.Stub(statusCode: 403, body: Data(#"{"error": "access_denied", "error_description": "Caller lacks the dj role."}"#.utf8)))
        
        let userCode = "ABCD-1234"
        let message = await viewModel.approve(userCode: userCode)
        
        #expect(message == "Your account can’t approve this. Approving requires a DJ role.")
        #expect(session.recordedRequests.count == baseline + 1)
    }

    /// A failed approve must reach a rendered state. The old suite asserted
    /// only `approve()`'s return value, which was correct all along — the bug was
    /// that nothing on screen ever read it.
    @Test func approveFailureRendersOnRequestSheet() async throws {
        let session = StubRequestSession()
        let auth = try await DeviceAuthViewModelTests.makeAuth(session: session)
        let viewModel = Self.makeViewModel(auth)
        let userCode = "ABCD-1234"
        viewModel.workflowState = .readyToApprove   // verify reported `pending`
        let stateBefore = viewModel.workflowState

        session.enqueue(StubRequestSession.Stub(statusCode: 400, body: Data(#"{"error": "expired_token", "error_description": "Code expired."}"#.utf8)))
        _ = await viewModel.approve(userCode: userCode)

        let expected = "This code is invalid or expired. Ask for a fresh QR."
        #expect(viewModel.approveError == expected)
        // A failure leaves the workflow where it was, so the sheet stays on the
        // request screen — which is now where the failure is drawn.
        #expect(viewModel.workflowState == stateBefore)
        #expect(Self.renderedSheet(viewModel, userCode: userCode) == .request(userCode: userCode, approveError: expected))
    }

    @Test func approveRetryClearsPreviousFailure() async throws {
        let session = StubRequestSession()
        let auth = try await DeviceAuthViewModelTests.makeAuth(session: session)
        let viewModel = Self.makeViewModel(auth)
        let userCode = "ABCD-1234"

        session.enqueue(StubRequestSession.Stub(statusCode: 403, body: Data(#"{"error": "access_denied", "error_description": "Caller lacks the dj role."}"#.utf8)))
        _ = await viewModel.approve(userCode: userCode)
        #expect(viewModel.approveError != nil)

        session.enqueue(StubRequestSession.Stub(statusCode: 200, body: Data(#"{"success": true}"#.utf8)))
        _ = await viewModel.approve(userCode: userCode)

        #expect(viewModel.approveError == nil)
        #expect(Self.renderedSheet(viewModel, userCode: userCode) == .approved(toast: "Approved — browser session started"))
    }

    @Test func sheetContentWithoutUserCodeFallsBackToErrorView() {
        let content = DeviceAuthViewModel.sheetContent(
            workflowState: .readyToApprove,
            userCode: nil,
            approveError: nil,
            fallbackMessage: "Unknown code"
        )
        #expect(content == .error("Unknown code"))
    }

    // MARK: - Verify status gate

    private static func verifyBody(_ status: String) -> Data {
        Data(#"{"user_code": "ABCD-1234", "status": "\#(status)"}"#.utf8)
    }

    @Test func verifyPendingOffersApprove() async throws {
        let session = StubRequestSession()
        let auth = try await DeviceAuthViewModelTests.makeAuth(session: session)
        let viewModel = Self.makeViewModel(auth)

        session.enqueue(StubRequestSession.Stub(statusCode: 200, body: Self.verifyBody("pending")))
        await viewModel.verify(userCode: "ABCD-1234")

        #expect(viewModel.workflowState == .readyToApprove)
        #expect(Self.renderedSheet(viewModel, userCode: "ABCD-1234") == .request(userCode: "ABCD-1234", approveError: nil))
    }

    /// Two DJs, one QR: the first approves, the second scans before the browser
    /// navigates. Verify answers 200 — the second phone must not offer Approve.
    @Test func verifyAlreadyApprovedDoesNotOfferApprove() async throws {
        let session = StubRequestSession()
        let auth = try await DeviceAuthViewModelTests.makeAuth(session: session)
        let viewModel = Self.makeViewModel(auth)

        session.enqueue(StubRequestSession.Stub(statusCode: 200, body: Self.verifyBody("approved")))
        await viewModel.verify(userCode: "ABCD-1234")

        let expected = "This sign-in was already approved. If the browser isn’t signed in, ask for a fresh QR."
        #expect(viewModel.workflowState == .unrecognized(expected))
        #expect(Self.renderedSheet(viewModel, userCode: "ABCD-1234") == .error(expected))
    }

    @Test func verifyAlreadyDeniedDoesNotOfferApprove() async throws {
        let session = StubRequestSession()
        let auth = try await DeviceAuthViewModelTests.makeAuth(session: session)
        let viewModel = Self.makeViewModel(auth)

        session.enqueue(StubRequestSession.Stub(statusCode: 200, body: Self.verifyBody("denied")))
        await viewModel.verify(userCode: "ABCD-1234")

        let expected = "This sign-in was already rejected. Ask for a fresh QR."
        #expect(viewModel.workflowState == .unrecognized(expected))
        #expect(Self.renderedSheet(viewModel, userCode: "ABCD-1234") == .error(expected))
    }

    @Test func verifyUnrecognizedStatusFailsClosed() async throws {
        let session = StubRequestSession()
        let auth = try await DeviceAuthViewModelTests.makeAuth(session: session)
        let viewModel = Self.makeViewModel(auth)

        session.enqueue(StubRequestSession.Stub(statusCode: 200, body: Self.verifyBody("expired")))
        await viewModel.verify(userCode: "ABCD-1234")

        #expect(viewModel.workflowState == .unrecognized("Unknown error. Try again later."))
    }

    /// Before verify answers, the code may already be consumed — no Approve yet.
    @Test func verifyingStateDoesNotOfferApprove() {
        let content = DeviceAuthViewModel.sheetContent(
            workflowState: .verifying,
            userCode: "ABCD-1234",
            approveError: nil,
            fallbackMessage: "Unknown code"
        )
        #expect(content == .verifying)
    }

    @Test func actionFailureMessageCoversEveryArm() {
        let map = DeviceAuthViewModel.actionFailureMessage(for:)
        #expect(map(DeviceAuthActionFailure(status: 401, code: .unauthorized)) == "You’re not signed in.")
        #expect(map(DeviceAuthActionFailure(status: 403, code: .accessDenied)) == "Your account can’t approve this. Approving requires a DJ role.")
        #expect(map(DeviceAuthActionFailure(status: 400, code: .invalidRequest)) == "This code is invalid or expired. Ask for a fresh QR.")
        #expect(map(DeviceAuthActionFailure(status: 400, code: .expiredToken)) == "This code is invalid or expired. Ask for a fresh QR.")
        #expect(map(DeviceAuthActionFailure(status: 500, code: nil)) == "Unknown error. Try again later.")
        #expect(map(DeviceAuthActionFailure(status: 400, code: .unknownDefaultOpenApi)) == "Unknown error. Try again later.")
        // No session token: thrown before any request, so it is not a network error.
        #expect(map(AuthError.notSignedIn) == "You’re not signed in.")
        #expect(map(AuthError.network(message: "Non-HTTP response")) == "Network error. Try again later.")
        // `AuthService.send` rethrows a transport `URLError` untouched.
        #expect(map(URLError(.notConnectedToInternet)) == "Network error. Try again later.")
        #expect(map(URLError(.badURL)).hasPrefix("An unexpected error occurred: "))
    }
    
    @Test func approveUnauthorizedError401() async throws {
        let session = StubRequestSession()
        let auth = try await DeviceAuthViewModelTests.makeAuth(session: session)
        let viewModel = Self.makeViewModel(auth)
        
        let errorBody = Data(#"{"error": "unauthorized", "error_description": "Caller not signed in."}"#.utf8)
        session.enqueue(StubRequestSession.Stub(statusCode: 401, body: errorBody))
        session.enqueue(StubRequestSession.Stub(statusCode: 200, body: Data(#"{"token":"\#(Fixtures.jwt())"}"#.utf8)))
        session.enqueue(StubRequestSession.Stub(statusCode: 401, body: errorBody))

        let userCode = "ABCD-1234"
        let message = await viewModel.approve(userCode: userCode)
        
        #expect(message == "You’re not signed in.")
    }
    
    @Test func denySuccessForDJ() async throws {
        let session = StubRequestSession()
        let auth = try await DeviceAuthViewModelTests.makeAuth(session: session)
        let viewModel = Self.makeViewModel(auth)
        let baseline = session.recordedRequests.count
        
        let userCode = "ABCD-1234"
        session.enqueue(StubRequestSession.Stub(statusCode: 200, body: Data(#"{"success": true}"#.utf8)))
        
        let message = await viewModel.deny(userCode: userCode)
        
        #expect(message == "Rejected — browser session was not started")
        #expect(session.recordedRequests.count == baseline + 1)
    }
}
