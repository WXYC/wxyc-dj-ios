//
//  QRDeviceVerify.swift
//  WXYCAPI
//
//  Types for POST /auth/device/verify — the iOS-side of ADR 0002's RFC 8628
//  device authorization. The control-room browser shows a QR pointing at
//  https://dj.wxyc.org/auth/device?user_code=DXFP-92QR; the iOS app scans it,
//  posts the user_code (plus action="approve"|"deny") with the DJ's current
//  Bearer JWT, and the browser's next poll receives a 12-hour session. The
//  method itself lives on ``APIClient`` so it can reuse the private transport
//  + 401-retry chain.
//
//  Created by Jake on 6/28/26.
//  Copyright © 2026 WXYC. All rights reserved.
//

import Foundation

/// Wire body for `POST /auth/device/verify` — the iOS side of ADR 0002.
/// `user_code` is the short human-friendly handle the browser also rendered in
/// plain text (e.g. `DXFP-92QR`); `action` is `"approve"` (issue a session) or
/// `"deny"` (the browser's poll learns `access_denied`).
struct DeviceVerifyRequest: Encodable, Sendable {
    let userCode: String
    let action: Action

    enum Action: String, Encodable, Sendable {
        case approve
        case deny
    }

    enum CodingKeys: String, CodingKey {
        case userCode = "user_code"
        case action
    }
}

/// 400-body shape Backend-Service emits when the verify is refused.
/// `error` is one of the RFC 8628 sentinels (`access_denied`,
/// `expired_token`, `invalid_grant`); `error_description` is the
/// human-readable detail surfaced in the rejection UI.
struct DeviceVerifyErrorBody: Decodable, Sendable {
    let error: String
    let errorDescription: String?

    enum CodingKeys: String, CodingKey {
        case error
        case errorDescription = "error_description"
    }
}

/// Distinguishes the failure modes the QR-sign-in flow needs to render
/// differently. ``transport`` wraps any other ``APIError`` (unreachable
/// backend, decoding failure, 5xx) so the view model can present a
/// generic retryable error.
public enum QRSignInError: Error, Sendable, Equatable {
    /// The scanned payload wasn't a recognized `dj.wxyc.org/auth/device` URL,
    /// so we never sent the verify. UI: "Couldn't read that code."
    case invalidPayload
    /// Server refused the verify (RFC 8628 `access_denied` / `expired_token` /
    /// `invalid_grant`). The associated `reason` is the server's human-readable
    /// `error_description` when one was supplied — surfaced verbatim in the
    /// rejection UI. Empty if the server omitted it.
    case accessDenied(reason: String)
    /// Local JWT role is below `dj`. UI: prototype's denial card.
    /// The associated role is the JWT's claim verbatim (`"member"`, `nil`,
    /// etc.) for the denial copy.
    case roleNotPermitted(role: String?)
    /// No DJ is signed in (or the JWT couldn't be obtained). The QR flow
    /// requires an authenticated session; ADR 0002 explicitly notes the iOS
    /// app must already be signed in to scan.
    case notSignedIn
    /// The DJ cancelled the biometric prompt. Not a failure — the view model
    /// returns to the approval state so they can retry.
    case biometricCancelled
    /// Any other transport failure (network, decoding, 5xx). Wraps the
    /// underlying ``APIError`` for diagnostics.
    case transport(APIError)

    public static func == (lhs: QRSignInError, rhs: QRSignInError) -> Bool {
        switch (lhs, rhs) {
        case (.invalidPayload, .invalidPayload),
             (.notSignedIn, .notSignedIn),
             (.biometricCancelled, .biometricCancelled):
            return true
        case (.accessDenied(let a), .accessDenied(let b)):
            return a == b
        case (.roleNotPermitted(let a), .roleNotPermitted(let b)):
            return a == b
        case (.transport, .transport):
            // APIError isn't Equatable; compare cases only — good enough for
            // assertion granularity in the view-model tests.
            return true
        default:
            return false
        }
    }

    public var localizedMessage: String {
        switch self {
        case .invalidPayload:
            return "Couldn't read that QR code."
        case .accessDenied(let reason):
            return reason.isEmpty
                ? "The sign-in was refused. The code may have expired — re-scan from the browser."
                : reason
        case .roleNotPermitted:
            return "Your account doesn't have permission to authorize browser sign-in."
        case .notSignedIn:
            return "Please sign in before scanning."
        case .biometricCancelled:
            return "Biometric check was cancelled."
        case .transport(let inner):
            return inner.localizedMessage
        }
    }
}
