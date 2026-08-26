//
//  DeviceAuthViewModelTests.swift
//  WXYCDJ
//
//  Created by Meira Volk on 8/19/26.
//

import Foundation
import Testing
@testable import WXYCAPI
@testable import WXYCDJ

@Suite("DeviceAuthViewModel", .serialized)
@MainActor
struct DeviceAuthViewModelTests {
    private static func makeViewModel(_ client: APIClient) -> DeviceAuthViewModel {
        return DeviceAuthViewModel(api: client)
    }
    @Test func approveSuccess() async throws {
        let (client, session) = try await SignedInClient.make()
        let viewModel = Self.makeViewModel(client)
        let baseline = session.recordedRequests.count
        
        let userCode = "ABCD-1234"
        
        //should I just copy the outcome of the api approve tests?, like the stub 200 thing?
        session.enqueue(StubRequestSession.Stub(statusCode: 200, body: Data(#"{"success": true}"#.utf8)))
        
        let message = await viewModel.approve(userCode: userCode)
        
        #expect(message == "Approved — the browser is now signed in.")
        #expect(session.recordedRequests.count == baseline + 1)
    }
    
    @Test func approveAcessDeniedError403() async throws {
        //the client and session looks slightly different than the wxycapi tests:
        //WXYCAPI/APIClientTests Version: let (client, _, session) = try await Self.makeSignedInClient()
        let (client, session) = try await SignedInClient.make()
        let viewModel = Self.makeViewModel(client)
        let baseline = session.recordedRequests.count
        
        session.enqueue(StubRequestSession.Stub(statusCode: 403, body: Data(#"{"error": "access_denied", "error_description": "Caller lacks the dj role."}"#.utf8)))
        
        
        //should I just copy the outcome of the api approve tests?, like the stub 200 thing?
        let userCode = "ABCD-1234"
        let message = await viewModel.approve(userCode: userCode)
        
        
        //I don't know what this does

        #expect(message == "Your account can’t approve this. Approving requires a DJ role.")
        #expect(session.recordedRequests.count == baseline + 1)
    }
    
    @Test func approveUnauthorizedError401() async throws {
        let (client, session) = try await SignedInClient.make()
        let viewModel = Self.makeViewModel(client)
        let baseline = session.recordedRequests.count
        
        let errorBody = Data(#"{"error": "unauthorized", "error_description": "Caller not signed in."}"#.utf8)
        
        //Do I still need three of the stub things
        //initial request error response
        session.enqueue(StubRequestSession.Stub(statusCode: 401, body: errorBody))
        
        //API Client tries to refresh token
        session.enqueue(StubRequestSession.Stub(statusCode: 200, body: Data(#"{"token":"\#(Fixtures.jwt())"}"#.utf8)))
        
        //fails again
        session.enqueue(StubRequestSession.Stub(statusCode: 401, body: errorBody))

        let userCode = "ABCD-1234"
        let message = await viewModel.approve(userCode: userCode)
        
        #expect(message == "You’re not signed in.")
    }
    
    @Test func denySuccess() async throws {
        let (client, session) = try await SignedInClient.make()
        let viewModel = Self.makeViewModel(client)
        let baseline = session.recordedRequests.count
        
        let userCode = "ABCD-1234"
        
        //is the the success method for deny? I just copied this from approve
        session.enqueue(StubRequestSession.Stub(statusCode: 200, body: Data(#"{"success": true}"#.utf8)))
        
        let message = await viewModel.deny(userCode: userCode)
        
        
        //I don't know what this does

        #expect(message == "Denied.")
        #expect(session.recordedRequests.count == baseline + 1)
    }
    
    
}
