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

public typealias DeviceAuthActionErrorCode = WXYCAPIModels.DeviceAuthActionErrorCode
public typealias DeviceAuthVerifyErrorCode = WXYCAPIModels.DeviceAuthVerifyErrorCode

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
    public init(status: Int, code: DeviceAuthActionErrorCode?) {
        self.status = status
        self.code = code
    }
}

struct DeviceAuthVerifyErrorEnvelope: Decodable, Sendable {
    let error: String
    let errorDescription: String
    enum CodingKeys: String, CodingKey {
        case error
        case errorDescription = "error_description"
    }
}

public struct DeviceAuthVerifyError: Error, Sendable, Equatable {
    public let status: Int
    public let code: DeviceAuthVerifyErrorCode?   // nil = missing/unknown code
    public init(status: Int, code: DeviceAuthVerifyErrorCode?) {
        self.status = status
        self.code = code
    }
}
