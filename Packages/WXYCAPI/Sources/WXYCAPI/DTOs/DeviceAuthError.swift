//
//  DeviceAuthError.swift
//  WXYCAPI
//
//  Created by Meira Volk on 8/1/26.
//code from QR_LOGIN_HANDOFF.md

import Foundation

// The typed codes. Decode defensively (see below) so an unknown code can't crash.
public enum DeviceAuthActionErrorCode: String, Sendable {
    case invalidRequest = "invalid_request"
    case expiredToken   = "expired_token"
    case unauthorized                        // wire value already "unauthorized"
    case accessDenied   = "access_denied"
}

// Internal: matches the raw { error, error_description } body. `error` decoded
// as String (not the enum) so an unknown code degrades instead of throwing.
struct DeviceAuthActionErrorEnvelope: Decodable, Sendable {
    let error: String
    let errorDescription: String
    enum CodingKeys: String, CodingKey {
        case error
        case errorDescription = "error_description"
    }
}
// The public error your UI catches. Carries the HTTP status AND the typed code,
// so the UI can tell 401 (not signed in) from 403 (not a DJ).
public struct DeviceAuthActionError: Error, Sendable, Equatable {
    public let status: Int
    public let code: DeviceAuthActionErrorCode?   // nil = missing/unknown code
}

//analog for verify error codes

public enum DeviceAuthVerifyErrorCode: String, Sendable {
    //only has invalid_request and expired_token
    case invalidRequest = "invalid_request"
    case expiredToken   = "expired_token"
}

struct DeviceAuthVerifyErrorEnvelope: Decodable, Sendable {
    let error: String
    let errorDescription: String
    enum CodingKeys: String, CodingKey {
        case error
        case errorDescription = "error_description"
    }
}
//do i need the thing below too?
public struct DeviceAuthVerifyError: Error, Sendable, Equatable {
    public let status: Int
    public let code: DeviceAuthVerifyErrorCode?   // nil = missing/unknown code
}
