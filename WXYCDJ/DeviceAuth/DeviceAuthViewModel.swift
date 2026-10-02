//
//  DeviceAuthViewModel.swift
//  WXYCDJ
//
//  Manages workflow state, active connection context, and approval logic for QR device authentication.
//
//  Created by Meira Volk on 08/12/26.
//  Copyright © 2026 WXYC. All rights reserved.
//

import Foundation
import Observation
import WXYCAPI

@MainActor
@Observable
final class DeviceAuthViewModel {
    var scannedCode: String?
    private let auth: AuthService
    
    // Active Connection Context Properties
    /*
     var hostDomain: String = "dj.wxyc.org"
     var username: String = "biscuit"
     var userRole: String = "DJ"
     */
    
    var requestDate: Date = Date()
    
    init(auth: AuthService) {
        self.auth = auth
    }
    /// Checks user role
    /*
    var isMember: Bool {
        if case .signedIn(let payload) = auth.state {
            //TO-DO: there could be a lot of different roles like stationmanager or dj or member, so for now I'm just
            //considering the case where the role is nil
            return payload?.role?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() != nil
        }
        return false
    }
    */
        
        //TO-DO: Add a member verification thing using the authservice?
        
        /*
        
        func updateUserProfile(role: String?, username: String? = nil) {
            if let role, !role.isEmpty {
                self.userRole = role.uppercased()
            }
            if let username, !username.isEmpty {
                self.username = username
            }
        }
        */
        
        enum AuthWorkflowState: Sendable, Equatable {
            case verifying
            case readyToApprove
            case approved(String)
            case unrecognized(String)
        }
        
        var workflowState: AuthWorkflowState = .verifying
        
        func processCode(scannedCode: String?) -> String? {
            guard let code = scannedCode else {
                self.workflowState = .unrecognized("Could not read QR code.")
                return nil
            }
            let userCode = DeviceCodeParser.userCode(fromScanned: code)
            Task {
                if let verifyCode = userCode {
                    await verify(userCode: verifyCode)
                } else {
                    self.workflowState = .unrecognized("Could not read QR code.")
                }
            }
            return userCode
        }
        
        func approve(userCode: String) async -> String {
            //ADD isMember variable to class once you figure out the token situation
            // TO-DO: add back in if we end up doing
            /*
            if isMember {
                return "Your account can’t approve this. Approving requires a DJ role."
            }
            */
            do {
                _ = try await auth.approveDevice(userCode: userCode)
                let successMessage = "Approved — browser session started"
                self.workflowState = .approved(successMessage)
                return successMessage
            } catch let e as DeviceAuthActionError {
                switch (e.status, e.code) {
                case (401, .unauthorized):
                    return "You’re not signed in."
                case (403, .accessDenied):
                    return "Your account can’t approve this. Approving requires a DJ role."
                case (400, .invalidRequest), (400, .expiredToken):
                    return "This code is invalid or expired. Ask for a fresh QR."
                default:
                    return "Unknown error. Try again later."
                }
            } catch _ as AuthError {
                return "Network error. Try again later."
            } catch {
                return "An unexpected error occurred: \(error.localizedDescription)."
            }
        }
        
        func deny(userCode: String) async -> String {
            do {
                _ = try await auth.denyDevice(userCode: userCode)
                return "Closed — browser session was not started"
                
                /*
                return isMember ? "Closed — browser session was not started" : "Rejected — browser session was not started"
                 */
            } catch let e as DeviceAuthActionError {
                switch (e.status, e.code) {
                case (401, .unauthorized):
                    return "You’re not signed in."
                case (403, .accessDenied):
                    return "Your account can’t approve this. Approving requires a DJ role."
                case (400, .invalidRequest), (400, .expiredToken):
                    return "This code is invalid or expired. Ask for a fresh QR."
                default:
                    return "Unknown error. Try again later."
                }
            } catch _ as AuthError {
                return "Network error"
            } catch {
                return "An unexpected error occurred: \(error.localizedDescription)"
            }
        }
        
        func verify(userCode: String) async {
            workflowState = .verifying
            do {
                _ = try await auth.verifyDevice(userCode: userCode)
                requestDate = Date()
                workflowState = .readyToApprove
            } catch let e as DeviceAuthVerifyError {
                switch (e.status, e.code) {
                case (400, .invalidRequest), (400, .expiredToken):
                    workflowState = .unrecognized("This code is invalid or expired. Ask for a fresh QR.")
                default:
                    workflowState = .unrecognized("Unknown error. Try again later.")
                }
            } catch {
                workflowState = .unrecognized("Network error. Try again later.")
            }
        }
    }

