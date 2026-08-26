//
//  DeviceAuthViewModel.swift
//  WXYCDJ
//
//  Created by Meira Volk on 8/12/26.
//

import Foundation
import Observation
import WXYCAPI
import SwiftUI //Added for Binding variable

@MainActor
@Observable
final class DeviceAuthViewModel {
    @Binding var scannedCode: String?
    private let api: APIClient
    
  
    
    //possible outcomes of the scan include: valid userCode, not recognized qrCode, loading / polling the authservice
    //so we'll copy the SearchView Enum set up to account for these
    
    enum State: Sendable, Equatable {
        case valid
        case loading
        case invalid
    }
    
    init(api: APIClient /*need to put in something for scannedCode too? */) {
        self.api = api
        self.scannedCode = scannedCode
    }
    
    func processCode(scannedCode: String?) -> String? {
        let userCode = DeviceCodeParser.userCode(fromScanned: scannedCode!)
        return userCode
    }

    
    //Is it necessary to check if they're signed in
    var canApprove: Bool {
        auth.state != .signingIn
    }
    
    func approve(userCode: String) async -> String {
        guard canApprove else { return "Not Signed In" } // may not be necessary
        //don't know if the function already catches errors for
        do {
            _ = try await api.approveDevice(userCode: userCode)
            return "Approved — the browser is now signed in." // 200 -- success
        } catch let e as DeviceAuthActionError {
            //for typed cases
            switch (e.status, e.code) {
            case (401, .unauthorized):
                return "You’re not signed in." //QR_LOGIN_HANDOFF says "and re-auth", send back to login screen or something?
            case (403, .accessDenied):
                return "Your account can’t approve this. Approving requires a DJ role."
            case (400, .invalidRequest):
                return "This code is invalid or expired. Ask for a fresh QR."
            case (400, .expiredToken):
                return "This code is invalid or expired. Ask for a fresh QR."
            case (400, nil):
                return "Invalid attempt. Unknown error."
            default:
                return "Unknown error. Try a fresh " // unknown error
            }
        }
        catch let e as APIError {
            //for transport errors
            return "Network error"
            }
    }
    
    
    func deny() async {
        guard canApprove else { return }
        do {
            await api.denyDevice(userCode: userCode)
            
        
        } catch let e as DeviceAuthActionError {
            //for typed cases
            switch (e.status, e.code) { … }
        }
        catch let e as APIError {
            //for transport errors
            }
    }
    //The QR_LOGIN_HANDOFF mentioned an optional verify option but I'm not quite sure what it means
    func verify() async {
        guard canApprove else { return }
        do {
            await api.verifyDevice(userCode: userCode)
            
        
        } catch let e as DeviceAuthActionError {
            //for typed cases
            switch (e.status, e.code) { … }
        }
        catch let e as APIError {
            //for transport errors
            }
    }
    //Just in case we need a func to handle different error messages
    private func handleError(_ message: String) {
        
    }
    
    //should also account for API error?
    /*

    
  
    
    var userCode = DeviceCodeParser.userCode(fromScanned: scannedCode)
 */
}
