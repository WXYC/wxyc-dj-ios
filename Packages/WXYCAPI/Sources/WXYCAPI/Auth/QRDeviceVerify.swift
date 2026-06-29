//
//  QRDeviceVerify.swift
//  WXYCAPI
//
//  Types for POST /auth/device/approve and POST /auth/device/deny — the iOS
//  side of ADR 0002's RFC 8628 device authorization. The control-room browser
//  shows a QR pointing at https://dj.wxyc.org/auth/device?user_code=DXFP-92QR;
//  the iOS app scans it and POSTs the userCode (with the DJ's Bearer session)
//  to either /device/approve or /device/deny. The methods themselves live on
//  ``APIClient`` so they can reuse the private transport + 401-retry chain.
//
//  Wire shape verified against wxyc-shared/api.yaml (issue #195, shipped in
//  @wxyc/shared@1.14.0). Casing is intentionally asymmetric — the approve/deny
//  request bodies are camelCase `userCode`; the verify-status lookup at
//  GET /auth/device uses snake_case `user_code`.
//
//  Created by Jake on 6/28/26.
//  Copyright © 2026 WXYC. All rights reserved.
//

import Foundation

/// Wire body for `POST /auth/device/approve` and `POST /auth/device/deny`.
/// `userCode` is the short human-friendly handle the browser also rendered in
/// plain text (e.g. `DXFP-92QR`).
///
/// Casing note: the field is camelCase on the wire — the better-auth plugin's
/// approve/deny bodies use `userCode`, while the snake_case `user_code` form
/// only appears on the `GET /auth/device` lookup. Both are pinned via explicit
/// ``CodingKeys``; do not "normalize" the mismatch.
struct DeviceAuthActionRequest: Encodable, Sendable {
    let userCode: String

    enum CodingKeys: String, CodingKey {
        case userCode
    }
}

/// Successful response from `/auth/device/approve` and `/auth/device/deny`.
/// `success` is always `true` on a 2xx; the body is checked anyway so a
/// future server change (an extra status field, a 200 with `success: false`)
/// surfaces here rather than silently passing.
struct DeviceAuthActionResponse: Decodable, Sendable {
    let success: Bool
}

/// Typed error body for /device/approve and /device/deny — the
/// `DeviceAuthActionError` shape in api.yaml. `error` is one of the
/// ``DeviceAuthActionErrorCode`` strings; `error_description` is the
/// human-readable detail surfaced in the rejection UI.
struct DeviceAuthActionErrorBody: Decodable, Sendable {
    let error: String
    let errorDescription: String?

    enum CodingKeys: String, CodingKey {
        case error
        case errorDescription = "error_description"
    }
}

/// The closed set of error codes emitted by /auth/device/approve and /deny,
/// shared across all their HTTP statuses (the api.yaml endpoint enum). Any
/// `error` string outside this set falls through to the view model's generic
/// transport-error path rather than a typed branch.
public enum DeviceAuthActionErrorCode: String, Sendable, Equatable {
    case invalidRequest = "invalid_request"
    case expiredToken = "expired_token"
    case unauthorized
    case accessDenied = "access_denied"
}

/// Distinguishes the failure modes the QR-sign-in flow needs to render
/// differently. ``transport`` wraps any other ``APIError`` (unreachable
/// backend, decoding failure, 5xx) so the view model can present a
/// generic retryable error.
public enum QRSignInError: Error, Sendable, Equatable {
    /// The scanned payload wasn't a recognized `dj.wxyc.org/auth/device` URL,
    /// so we never sent the verify. UI: "Couldn't read that code."
    case invalidPayload
    /// `403 access_denied` — caller is not the claiming user, or lacks the
    /// `dj` role (the auth-service role gate). `reason` is the server's
    /// `error_description` verbatim, surfaced in the rejection UI.
    case accessDenied(reason: String)
    /// `400 expired_token` — the QR code already aged out. UI suggests
    /// re-scanning a fresh code from the browser.
    case expiredCode(reason: String)
    /// `400 invalid_request` — unknown / unclaimed / already-processed code.
    /// Same UI as `.expiredCode` (re-scan); kept distinct for telemetry.
    case invalidCode(reason: String)
    /// Local JWT role is below `dj`. UI: prototype's denial card.
    /// The associated role is the JWT's claim verbatim (`"member"`, `nil`,
    /// etc.) for the denial copy.
    case roleNotPermitted(role: String?)
    /// No DJ is signed in (or the JWT couldn't be obtained). The QR flow
    /// requires an authenticated session; ADR 0002 explicitly notes the iOS
    /// app must already be signed in to scan. Also covers the server-side
    /// `401 unauthorized` arm — the JWT was rejected mid-call.
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
        case (.accessDenied(let a), .accessDenied(let b)),
             (.expiredCode(let a), .expiredCode(let b)),
             (.invalidCode(let a), .invalidCode(let b)):
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
                ? "Your account doesn't have permission to authorize browser sign-in."
                : reason
        case .expiredCode(let reason):
            return reason.isEmpty
                ? "The QR code has expired — re-scan the new one from the browser."
                : reason
        case .invalidCode(let reason):
            return reason.isEmpty
                ? "That code can't be used. Re-scan from the browser."
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
