//
//  DeviceAuth.swift
//  WXYCAPI
//
//  Created by Meira Volk on 8/7/26.
//

import Foundation

// userCode matches the camelCase wire key, so NO CodingKeys needed:
public struct DeviceAuthApproveRequest: Encodable, Sendable {
    public let userCode: String
    public init(userCode: String) { self.userCode = userCode }
}
public struct DeviceAuthDenyRequest: Encodable, Sendable {
    public let userCode: String
    public init(userCode: String) { self.userCode = userCode }
}

// success matches, so NO CodingKeys:
public struct DeviceAuthActionResponse: Decodable, Sendable {
    public let success: Bool
}

public enum DeviceAuthStatus: String, Decodable, Sendable {
    case pending, approved, denied
}

// userCode vs. the wire's user_code DIFFERS, so CodingKeys IS required here:
public struct DeviceAuthVerifyResponse: Decodable, Sendable {
    public let userCode: String
    public let status: DeviceAuthStatus
    enum CodingKeys: String, CodingKey {
        case userCode = "user_code"
        case status                  // matches, but the enum must list every case
    }
}
