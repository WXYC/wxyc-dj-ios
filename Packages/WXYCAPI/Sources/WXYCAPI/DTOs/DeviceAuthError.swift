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

// The `{error, error_description}` bodies are decoded with the vendored
// `WXYCAPIModels.DeviceAuthActionError` / `DeviceAuthVerifyError` as-is. Their
// code enums are `CaseIterableDefaultsLast`, so a code the server adds later
// decodes to `.unknownDefaultOpenApi` rather than throwing.
//
// The two `Error` types below are deliberately *not* named after those
// schemas: a same-module declaration would silently shadow the imported
// generated type. They are not duplicates of it either — they pair the code
// with the HTTP status, which the body doesn't carry.

/// A non-200 answer from `AuthService.approveDevice` / `denyDevice`.
///
/// Carries the HTTP status **and** the typed code, because the status means
/// something on its own: `401` is "session rejected", `403` is "signed in but
/// not allowed" (the server's role gate), and the two must render differently.
/// `code` is `nil` when the body was missing or unparseable, and
/// `.unknownDefaultOpenApi` when it named a code this build doesn't know — the
/// status is preserved either way. The app maps it to copy in
/// `DeviceAuthViewModel.actionFailureMessage(for:)`.
public struct DeviceAuthActionFailure: Error, Sendable, Equatable {
    public let status: Int
    public let code: DeviceAuthActionErrorCode?   // nil = missing/unparseable body
    public init(status: Int, code: DeviceAuthActionErrorCode?) {
        self.status = status
        self.code = code
    }

    /// Decodes `body` as the vendored error schema. `try?`: an unparseable body
    /// still yields a typed failure, just with `code: nil` — the status alone
    /// distinguishes 401 from 403.
    init(status: Int, body: Data) {
        let decoded = try? JSONCoders.decoder.decode(WXYCAPIModels.DeviceAuthActionError.self, from: body)
        self.init(status: status, code: decoded?.error)
    }
}

/// A non-200 answer from `AuthService.verifyDevice`: the HTTP status plus the
/// typed code (`nil` for a missing or unparseable body). Note a consumed code
/// is **not** reported this way — verify answers `200` with a non-`pending`
/// status instead.
public struct DeviceAuthVerifyFailure: Error, Sendable, Equatable {
    public let status: Int
    public let code: DeviceAuthVerifyErrorCode?   // nil = missing/unparseable body
    public init(status: Int, code: DeviceAuthVerifyErrorCode?) {
        self.status = status
        self.code = code
    }

    /// Decodes `body` as the vendored error schema; see
    /// ``DeviceAuthActionFailure/init(status:body:)``.
    init(status: Int, body: Data) {
        let decoded = try? JSONCoders.decoder.decode(WXYCAPIModels.DeviceAuthVerifyError.self, from: body)
        self.init(status: status, code: decoded?.error)
    }
}
