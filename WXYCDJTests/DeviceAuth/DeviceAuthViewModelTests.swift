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
    
    private static func makeAuth(session: StubRequestSession, role: String = "dj") async throws -> AuthService {
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
    }
    
    /*
    //TO-DO: add back in when we pay attention to dj roles
    @Test func approveMemberRoleGateBlockedLocally() async throws {
        let session = StubRequestSession()
        let auth = try await DeviceAuthViewModelTests.makeAuth(session: session, role: "member")
        let viewModel = Self.makeViewModel(auth)
        let baseline = session.recordedRequests.count
        
        #expect(viewModel.isMember == true)
        
        let userCode = "ABCD-1234"
        let message = await viewModel.approve(userCode: userCode)
        
        #expect(message == "Your account can’t approve this. Approving requires a DJ role.")
        #expect(session.recordedRequests.count == baseline)
    }
    */
    
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
    
    @Test func denySuccessForMember() async throws {
        let session = StubRequestSession()
        let auth = try await DeviceAuthViewModelTests.makeAuth(session: session, role: "member")
        let viewModel = Self.makeViewModel(auth)
        let baseline = session.recordedRequests.count
        
        let userCode = "ABCD-1234"
        session.enqueue(StubRequestSession.Stub(statusCode: 200, body: Data(#"{"success": true}"#.utf8)))
        
        let message = await viewModel.deny(userCode: userCode)
        
        #expect(message == "Closed — browser session was not started")
        #expect(session.recordedRequests.count == baseline + 1)
    }
}
