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

/// Drives the QR approval sheet (`DeviceAuthView`): turns a scanned string into a
/// `user_code`, checks the code is still approvable, and approves or rejects it
/// through `AuthService` on the signed-in DJ's behalf.
///
/// Flow: `processCode(scannedCode:)` parses the scan and starts `verify(userCode:)`;
/// verify moves `workflowState` from `.verifying` to `.readyToApprove` only when the
/// server reports the code `pending`; the DJ then taps Approve (`approve(userCode:)`,
/// which on success moves to `.approved`) or Reject (`deny(userCode:)`, after which
/// the view dismisses with a toast). What the sheet renders for each state is the
/// pure `sheetContent(...)` decision, so it is testable without a view harness.
///
/// Built with `AuthService`, not `APIClient`: the device-auth routes need the
/// session token, which only `AuthService` holds (#164; see its "Device Auth"
/// section).
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
    
    /// When verify last confirmed the code `pending`; the sheet's
    /// "Requested Ns ago" counts from here.
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
        
        /// Where the approval flow is. A failed approve deliberately does **not**
        /// change this — the DJ stays on the request sheet and the failure is
        /// carried by `approveError` instead.
        enum AuthWorkflowState: Sendable, Equatable {
            /// Verify hasn't answered yet; Approve is not offered.
            case verifying
            /// Verify reported the code `pending`; Approve and Reject are offered.
            case readyToApprove
            /// Approve succeeded; carries the success toast copy.
            case approved(String)
            /// The scan or the code can't be acted on (unreadable QR, invalid or
            /// expired code, already approved/rejected, network failure); carries
            /// the copy the error sheet shows.
            case unrecognized(String)
        }
        
        var workflowState: AuthWorkflowState = .verifying

        /// The copy for the most recent failed `approve(userCode:)`, rendered on the
        /// request sheet beneath the permissions list. `nil` until an approve fails,
        /// and cleared at the start of every approve so a retry never shows the
        /// previous attempt's failure while it is in flight.
        ///
        /// This is observable state rather than a value the view stores, because a
        /// failed approve leaves `workflowState` untouched — so nothing else changes
        /// that the view could key a render on. Before this existed the button wrote
        /// its result into a `@State` read only by the `userCode == nil` branch,
        /// which can never be on screen while Approve is.
        var approveError: String?

        /// What the sheet shows. One pure decision, so the branch a failed approve
        /// lands in is testable rather than an inference from the view's `if` ladder
        /// — that ladder is where approve failures used to vanish.
        enum SheetContent: Sendable, Equatable {
            case approved(toast: String)
            case error(String)
            /// Verify hasn't answered yet. Approve must not be offered here: until
            /// the server says the code is `pending`, it may already be consumed.
            case verifying
            case request(userCode: String, approveError: String?)
        }

        nonisolated static func sheetContent(
            workflowState: AuthWorkflowState,
            userCode: String?,
            approveError: String?,
            fallbackMessage: String
        ) -> SheetContent {
            if case .approved(let toast) = workflowState {
                return .approved(toast: toast)
            }
            if case .unrecognized(let errorText) = workflowState {
                return .error(errorText)
            }
            if workflowState == .verifying {
                return .verifying
            }
            if let userCode {
                return .request(userCode: userCode, approveError: approveError)
            }
            return .error(fallbackMessage)
        }

        /// Maps an `approveDevice`/`denyDevice` failure to the copy the DJ sees.
        /// Shared by `approve` and `deny` so the two can't drift into different
        /// wording for the same server answer.
        ///
        /// Two arms are routed more precisely than the old per-method ladders did:
        /// `AuthError.notSignedIn` (thrown before any request when there is no
        /// session token) now reads "not signed in" rather than "Network error",
        /// and a raw connectivity-class `URLError` — which `AuthService.send`
        /// rethrows untouched — now reads as a network error rather than
        /// "An unexpected error occurred".
        nonisolated static func actionFailureMessage(for error: any Error) -> String {
            switch error {
            case let e as DeviceAuthActionError:
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
            case let e as AuthError where e == .notSignedIn:
                return "You’re not signed in."
            case is AuthError:
                return "Network error. Try again later."
            case _ where ConnectivityErrorClassification.isConnectivityFailure(error):
                return "Network error. Try again later."
            default:
                return "An unexpected error occurred: \(error.localizedDescription)"
            }
        }
        
        /// Copy for a code verify reports as no longer pending. `nil` means the code
        /// is pending and may be offered for approval.
        ///
        /// `GET /auth/device` answers `200` for a consumed code too, so a 2xx alone
        /// says nothing about whether Approve is safe to offer — e.g. two DJs at the
        /// control-room computer: the first approves, the browser hasn't navigated
        /// yet, the second scans the same QR and gets `{status: "approved"}`.
        /// An unrecognized status fails closed: offering Approve on a state this
        /// build can't name is the same defect as offering it on a consumed code.
        nonisolated static func nonPendingMessage(for status: DeviceAuthStatus) -> String? {
            switch status {
            case .pending:
                return nil
            case .approved:
                return "This sign-in was already approved. If the browser isn’t signed in, ask for a fresh QR."
            case .denied:
                return "This sign-in was already rejected. Ask for a fresh QR."
            case .unknownDefaultOpenApi:
                return "Unknown error. Try again later."
            }
        }
        
        /// Parses a scan and starts verifying it. Called once, when the sheet appears.
        ///
        /// - Parameter scannedCode: The raw string the camera decoded, or `nil`.
        /// - Returns: The parsed `user_code` for the view to hold (Approve/Reject
        ///   need it), or `nil` when nothing could be parsed — in which case
        ///   `workflowState` becomes `.unrecognized("Could not read QR code.")`.
        ///   Verify runs in an unstructured task, so `workflowState` is still
        ///   `.verifying` when this returns.
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
        
        /// Approves the browser sign-in for `userCode`.
        ///
        /// No device-owner check (Face ID / passcode) runs first — a deliberate
        /// decision recorded in ADR 0002's amendments; the phone being signed in
        /// is the only gate on the app side.
        ///
        /// Clears `approveError` first, so a retry never shows the previous
        /// attempt's failure while it is in flight. On success moves
        /// `workflowState` to `.approved`; on failure leaves `workflowState` alone
        /// and sets `approveError` to `actionFailureMessage(for:)`'s copy, which the
        /// request sheet renders above the buttons.
        ///
        /// - Returns: The success or failure copy (also reflected in state; the
        ///   view renders from state, the return value is for tests and callers
        ///   that want it).
        func approve(userCode: String) async -> String {
            //ADD isMember variable to class once you figure out the token situation
            // TO-DO: add back in if we end up doing
            /*
            if isMember {
                return "Your account can’t approve this. Approving requires a DJ role."
            }
            */
            approveError = nil
            do {
                _ = try await auth.approveDevice(userCode: userCode)
                let successMessage = "Approved — browser session started"
                self.workflowState = .approved(successMessage)
                return successMessage
            } catch {
                let message = Self.actionFailureMessage(for: error)
                approveError = message
                return message
            }
        }
        
        /// Rejects the browser sign-in for `userCode`.
        ///
        /// Changes no state: the view dismisses the sheet and shows the returned
        /// copy as a toast whether the call succeeded or failed.
        ///
        /// - Returns: "Rejected — browser session was not started" on success, or
        ///   `actionFailureMessage(for:)`'s copy on failure.
        func deny(userCode: String) async -> String {
            do {
                _ = try await auth.denyDevice(userCode: userCode)
                // "Closed" was the member-only wording, paired with the member
                // sheet's "Close" button. With the role gate removed every DJ sees
                // "Reject", so the toast says "Rejected" to match.
                return "Rejected — browser session was not started"
                
                /*
                return isMember ? "Closed — browser session was not started" : "Rejected — browser session was not started"
                 */
            } catch {
                return Self.actionFailureMessage(for: error)
            }
        }
        
        /// Checks that `userCode` is still approvable, and only then offers Approve.
        ///
        /// Sets `.verifying`, then: a `pending` status moves to `.readyToApprove`
        /// and restamps `requestDate`; any other status (already approved, already
        /// denied, unrecognized) moves to `.unrecognized` with
        /// `nonPendingMessage(for:)`'s copy; a `400` or other verify error, or any
        /// transport failure, moves to `.unrecognized` too.
        func verify(userCode: String) async {
            workflowState = .verifying
            do {
                let response = try await auth.verifyDevice(userCode: userCode)
                if let message = Self.nonPendingMessage(for: response.status) {
                    workflowState = .unrecognized(message)
                    return
                }
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

