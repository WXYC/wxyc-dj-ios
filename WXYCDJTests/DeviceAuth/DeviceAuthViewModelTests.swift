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
    private static func makeViewModel(_ client: APIClient) -> DeviceAuthViewModel {
        return DeviceAuthViewModel(api: client, biometricEvaluator: { true })
    }

    @Test func approveSuccess() async throws {
        let (client, session) = try await SignedInClient.make()
        let viewModel = Self.makeViewModel(client)
        let baseline = session.recordedRequests.count
        
        let userCode = "ABCD-1234"
        session.enqueue(StubRequestSession.Stub(statusCode: 200, body: Data(#"{"success": true}"#.utf8)))
        
        let message = await viewModel.approve(userCode: userCode)
        
        #expect(message == "Approved — browser session started")
        #expect(session.recordedRequests.count == baseline + 1)
    }
    
    @Test func approveMemberRoleGateBlockedLocally() async throws {
        let (client, session) = try await SignedInClient.make()
        let viewModel = Self.makeViewModel(client)
        viewModel.updateUserProfile(role: "MEMBER")
        let baseline = session.recordedRequests.count
        
        #expect(viewModel.isMember == true)
        
        let userCode = "ABCD-1234"
        let message = await viewModel.approve(userCode: userCode)
        
        #expect(message == "Your account can’t approve this. Approving requires a DJ role.")
        #expect(session.recordedRequests.count == baseline)
    }
    
    @Test func approveAccessDeniedError403() async throws {
        let (client, session) = try await SignedInClient.make()
        let viewModel = Self.makeViewModel(client)
        let baseline = session.recordedRequests.count
        
        session.enqueue(StubRequestSession.Stub(statusCode: 403, body: Data(#"{"error": "access_denied", "error_description": "Caller lacks the dj role."}"#.utf8)))
        
        let userCode = "ABCD-1234"
        let message = await viewModel.approve(userCode: userCode)
        
        #expect(message == "Your account can’t approve this. Approving requires a DJ role.")
        #expect(session.recordedRequests.count == baseline + 1)
    }
    
    @Test func approveUnauthorizedError401() async throws {
        let (client, session) = try await SignedInClient.make()
        let viewModel = Self.makeViewModel(client)
        
        let errorBody = Data(#"{"error": "unauthorized", "error_description": "Caller not signed in."}"#.utf8)
        session.enqueue(StubRequestSession.Stub(statusCode: 401, body: errorBody))
        session.enqueue(StubRequestSession.Stub(statusCode: 200, body: Data(#"{"token":"\#(Fixtures.jwt())"}"#.utf8)))
        session.enqueue(StubRequestSession.Stub(statusCode: 401, body: errorBody))

        let userCode = "ABCD-1234"
        let message = await viewModel.approve(userCode: userCode)
        
        #expect(message == "You’re not signed in.")
    }
    
    @Test func denySuccessForDJ() async throws {
        let (client, session) = try await SignedInClient.make()
        let viewModel = Self.makeViewModel(client)
        let baseline = session.recordedRequests.count
        
        let userCode = "ABCD-1234"
        session.enqueue(StubRequestSession.Stub(statusCode: 200, body: Data(#"{"success": true}"#.utf8)))
        
        let message = await viewModel.deny(userCode: userCode)
        
        #expect(message == "Rejected — browser session was not started")
        #expect(session.recordedRequests.count == baseline + 1)
    }
    
    @Test func denySuccessForMember() async throws {
        let (client, session) = try await SignedInClient.make()
        let viewModel = Self.makeViewModel(client)
        viewModel.updateUserProfile(role: "MEMBER")
        let baseline = session.recordedRequests.count
        
        let userCode = "ABCD-1234"
        session.enqueue(StubRequestSession.Stub(statusCode: 200, body: Data(#"{"success": true}"#.utf8)))
        
        let message = await viewModel.deny(userCode: userCode)
        
        #expect(message == "Closed — browser session was not started")
        #expect(session.recordedRequests.count == baseline + 1)
    }
}
