//
//  QRSignInViewModel.swift
//  WXYCDJ
//
//  State machine for the QR-sign-in flow (ADR 0002). Parses the scanned
//  payload, runs the client-side role gate (server is still source of truth),
//  drives Face ID, and POSTs /auth/device/verify. Designed against
//  BiometricAuthenticator + the parser function so unit tests can drive every
//  branch without spawning real Face ID or constructing a verification URL by
//  hand.
//
//  Created by Jake on 6/28/26.
//  Copyright © 2026 WXYC. All rights reserved.
//

import Foundation
import Observation
import OSLog
import WXYCAPI

private let qrLog = Logger(subsystem: "org.wxyc.dj", category: "qrsignin")

/// Roles ADR 0002 allows to authorize a browser sign-in. The set is closed —
/// adding a new station role to the backend's role enum requires deciding
/// here whether it can also bootstrap a control-room session.
private let permittedRoles: Set<String> = ["dj", "music_director", "station_manager", "engineer"]

@MainActor
@Observable
final class QRSignInViewModel {
    enum State: Equatable {
        /// Camera mounted, awaiting a frame containing a recognized QR.
        case scanning
        /// A payload was parsed; the approval card is showing for the DJ to
        /// approve or reject. `userCode` is the verbatim short code (not shown
        /// in the UI per ADR 0002, but kept here for the verify call).
        case approving(userCode: String)
        /// Face ID is in progress — `approve()` was tapped, biometric is running.
        case authenticating(userCode: String)
        /// `POST /auth/device/verify` is in flight. Used by the UI to disable
        /// the buttons; resolves to `.succeeded` or `.error`.
        case verifying(userCode: String, approve: Bool)
        /// DJ doesn't hold the role the ADR's gate allows. The `role` is the
        /// JWT's claim verbatim (or `nil` if the JWT had none). UI shows the
        /// denial card from the prototype.
        case roleGated(role: String?)
        /// `reject()` succeeded — the browser will see access_denied.
        case rejected
        /// Verify returned 2xx — the browser session is being minted.
        case succeeded
        /// Any other failure: bad payload, transport error, server denial.
        /// Carries the localizedMessage from ``QRSignInError`` so the UI need
        /// not switch on cases.
        case error(message: String)
    }

    private(set) var state: State

    private let api: APIClient
    private let authService: AuthService
    private let biometrics: any BiometricAuthenticator
    private let parser: @Sendable (String) throws -> String

    init(
        api: APIClient,
        authService: AuthService,
        biometrics: any BiometricAuthenticator,
        parser: @escaping @Sendable (String) throws -> String = QRSignInPayload.parse
    ) {
        self.api = api
        self.authService = authService
        self.biometrics = biometrics
        self.parser = parser
        // If the DJ isn't signed in at construction time, surface the error
        // immediately rather than letting them scan a code that can't be
        // approved. ADR 0002: the iOS app must already be signed in to scan.
        if authService.isSignedIn {
            self.state = .scanning
        } else {
            self.state = .error(message: QRSignInError.notSignedIn.localizedMessage)
        }
    }

    /// Called by the scanner view when a QR frame decodes. Parses the payload,
    /// runs the role gate, and transitions to `.approving` (or a terminal
    /// state). Idempotent against duplicate frames — once a payload has been
    /// accepted (any state but `.scanning`/`.error`), additional scans are
    /// ignored, so the AVFoundation delegate can keep delivering frames
    /// without driving the state forward.
    func handleScannedPayload(_ raw: String) {
        guard case .scanning = state else { return }
        guard authService.isSignedIn else {
            state = .error(message: QRSignInError.notSignedIn.localizedMessage)
            return
        }
        let userCode: String
        do {
            userCode = try parser(raw)
        } catch {
            qrLog.debug("QR payload rejected: \(raw, privacy: .private(mask: .hash))")
            state = .error(message: QRSignInError.invalidPayload.localizedMessage)
            return
        }
        // Proactive client role gate — short-circuits the verify when the
        // signed-in DJ's role is below `dj`. Server is the source of truth;
        // this just makes the UI immediate.
        let role = currentRole()
        if !roleIsPermitted(role) {
            state = .roleGated(role: role)
            return
        }
        state = .approving(userCode: userCode)
    }

    /// DJ tapped Approve. Runs Face ID, then `POST /auth/device/verify` with
    /// `action: "approve"`. A biometric cancel returns to `.approving` (so the
    /// DJ can retry); a verify 4xx surfaces as `.error`.
    func approve() async {
        guard case .approving(let userCode) = state else { return }
        state = .authenticating(userCode: userCode)
        do {
            let ok = try await biometrics.authenticate(
                reason: "Authorize browser sign-in on dj.wxyc.org"
            )
            guard ok else {
                state = .approving(userCode: userCode)
                return
            }
        } catch {
            qrLog.error("Biometric authentication failed: \(error.localizedDescription, privacy: .public)")
            state = .approving(userCode: userCode)
            return
        }
        await sendVerify(userCode: userCode, approve: true)
    }

    /// DJ tapped Reject. Tells the server (so the browser's poll resolves
    /// fast with `access_denied`) and surfaces `.rejected`. No biometric:
    /// declining doesn't grant anything, so the gate is unnecessary.
    func reject() async {
        guard case .approving(let userCode) = state else { return }
        state = .verifying(userCode: userCode, approve: false)
        await sendVerify(userCode: userCode, approve: false)
    }

    /// Called from the action-sheet "Close" button on a role-gated denial,
    /// from the success screen's Done, and from the cancel button on the
    /// scanner. Pure state reset for the host view's dismiss handler — no
    /// network call.
    func dismiss() {
        state = .scanning
    }

    // MARK: - Internals

    private func sendVerify(userCode: String, approve: Bool) async {
        state = .verifying(userCode: userCode, approve: approve)
        do {
            try await api.verifyDeviceCode(userCode: userCode, approve: approve)
            state = approve ? .succeeded : .rejected
        } catch let error as QRSignInError {
            state = .error(message: error.localizedMessage)
        } catch let error as APIError {
            state = .error(message: error.localizedMessage)
        } catch {
            state = .error(message: error.localizedDescription)
        }
    }

    private func currentRole() -> String? {
        guard case .signedIn(let payload) = authService.state else { return nil }
        return payload?.role
    }

    private func roleIsPermitted(_ role: String?) -> Bool {
        guard let role else { return false }
        return permittedRoles.contains(role.lowercased())
    }
}
