//
//  DeviceAuthError.swift
//  WXYCAPI
//
//  Error definitions and DTO aliases for device authorization requests.
//
//  Created by Meira Volk on 08/07/26.
//  Copyright © 2026 WXYC. All rights reserved.
//

import Foundation
import WXYCAPIModels

/// The `error` codes approve/deny can answer with: `invalid_request`,
/// `expired_token`, `unauthorized`, `access_denied`.
public typealias DeviceAuthActionErrorCode = WXYCAPIModels.DeviceAuthActionErrorCode
/// The `error` codes verify can answer with: `invalid_request`, `expired_token`.
public typealias DeviceAuthVerifyErrorCode = WXYCAPIModels.DeviceAuthVerifyErrorCode

/// The raw `{error, error_description}` body of a failed approve/deny. Internal:
/// callers see ``DeviceAuthActionError`` instead. `error` is decoded as a plain
/// `String`, not the enum, so a code the server adds later degrades to
/// `code: nil` rather than failing the decode.
struct DeviceAuthActionErrorEnvelope: Decodable, Sendable {
    let error: String
    let errorDescription: String
    enum CodingKeys: String, CodingKey {
        case error
        case errorDescription = "error_description"
    }
}

/// A non-200 answer from `AuthService.approveDevice` / `denyDevice`.
///
/// Carries the HTTP status **and** the typed code, because the status means
/// something on its own: `401` is "session rejected", `403` is "signed in but
/// not allowed" (the server's role gate), and the two must render differently.
/// `code` is `nil` when the body was missing, unparseable, or named a code this
/// build doesn't know — the status is preserved either way. The app maps it to
/// copy in `DeviceAuthViewModel.actionFailureMessage(for:)`.
public struct DeviceAuthActionError: Error, Sendable, Equatable {
    public let status: Int
    public let code: DeviceAuthActionErrorCode?   // nil = missing/unknown code
    public init(status: Int, code: DeviceAuthActionErrorCode?) {
        self.status = status
        self.code = code
    }
}

/// The raw `{error, error_description}` body of a failed verify; decoded
/// defensively for the same reason as ``DeviceAuthActionErrorEnvelope``.
struct DeviceAuthVerifyErrorEnvelope: Decodable, Sendable {
    let error: String
    let errorDescription: String
    enum CodingKeys: String, CodingKey {
        case error
        case errorDescription = "error_description"
    }
}

/// A non-200 answer from `AuthService.verifyDevice`: the HTTP status plus the
/// typed code (`nil` when missing or unrecognized). Note a consumed code is
/// **not** reported this way — verify answers `200` with a non-`pending`
/// status instead.
public struct DeviceAuthVerifyError: Error, Sendable, Equatable {
    public let status: Int
    public let code: DeviceAuthVerifyErrorCode?   // nil = missing/unknown code
    public init(status: Int, code: DeviceAuthVerifyErrorCode?) {
        self.status = status
        self.code = code
    }
}
