//
//  JWTPayload.swift
//  WXYCAPI
//
//  Minimal client-side JWT decoder. Reads the payload claims used by
//  Backend-Service (sub, email, role, exp) without verifying the signature —
//  the server validates that against JWKS on every request.
//
//  Created by Jake on 5/14/26.
//  Copyright © 2026 WXYC. All rights reserved.
//

import Foundation

public struct JWTPayload: Codable, Sendable, Equatable {
    public let sub: String?
    public let email: String?
    public let role: String?
    public let exp: Date

    public var expiration: Date { exp }

    public init(sub: String?, email: String?, role: String?, exp: Date) {
        self.sub = sub
        self.email = email
        self.role = role
        self.exp = exp
    }

    private enum CodingKeys: String, CodingKey {
        case sub, email, role, exp
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        sub = try c.decodeIfPresent(String.self, forKey: .sub)
        email = try c.decodeIfPresent(String.self, forKey: .email)
        role = try c.decodeIfPresent(String.self, forKey: .role)
        let seconds = try c.decode(TimeInterval.self, forKey: .exp)
        exp = Date(timeIntervalSince1970: seconds)
    }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encodeIfPresent(sub, forKey: .sub)
        try c.encodeIfPresent(email, forKey: .email)
        try c.encodeIfPresent(role, forKey: .role)
        try c.encode(exp.timeIntervalSince1970, forKey: .exp)
    }
}

public enum JWTDecodeError: Error, Sendable, Equatable {
    case malformed
    case base64DecodeFailed
    case payloadDecodeFailed
}

public enum JWTDecoder {
    public static func decode(_ token: String) throws -> JWTPayload {
        let segments = token.split(separator: ".", omittingEmptySubsequences: false)
        guard segments.count == 3 else { throw JWTDecodeError.malformed }
        let payloadSegment = String(segments[1])
        guard let data = base64URLDecode(payloadSegment) else {
            throw JWTDecodeError.base64DecodeFailed
        }
        do {
            return try JSONDecoder().decode(JWTPayload.self, from: data)
        } catch {
            throw JWTDecodeError.payloadDecodeFailed
        }
    }

    static func base64URLDecode(_ input: String) -> Data? {
        var s = input.replacing("-", with: "+").replacing("_", with: "/")
        let pad = s.count % 4
        if pad > 0 { s.append(String(repeating: "=", count: 4 - pad)) }
        return Data(base64Encoded: s)
    }
}
