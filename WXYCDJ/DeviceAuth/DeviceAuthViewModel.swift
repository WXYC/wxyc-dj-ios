//
//  DeviceAuthViewModel.swift
//  WXYCDJ
//
//  Created by Meira Volk on 8/12/26.
//

import Foundation
import Observation
import WXYCAPI

@MainActor
@Observable
final class DeviceAuthViewModel {
    var scannedCode: String?
    private let api: APIClient
    
    //Do I need to initialize scannedCode?
    init(api: APIClient /*need to put in something for scannedCode too? */) {
        self.api = api
    }

    func processCode(scannedCode: String?) -> String? {
        guard let code = scannedCode else { return nil }
        return DeviceCodeParser.userCode(fromScanned: code)
    }
    
    func approve(userCode: String) async -> String {
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
                return "Unknown error. Try again later." // unknown error
            }
        }
        catch let e as APIError {
            //for transport errors
            return "Network error. Try again later."
        }
        catch {
            return "An unexpected error occured: \(error.localizedDescription)."
        }
    }
    
    
    func deny(userCode: String) async -> String {
        do {
            _ = try await api.denyDevice(userCode: userCode)
            return "Denied."
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
                return "Unknown error. Try again later." // unknown error
            }
        }
        catch let e as APIError {
            //for transport errors
            return "Network error"
        }
        catch {
            return "An unexpected error occured: \(error.localizedDescription)"
        }
    }
    //The QR_LOGIN_HANDOFF mentioned an optional verify option but I'm not quite sure what it means
    /*
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
     */
}
