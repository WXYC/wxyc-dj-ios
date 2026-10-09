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

    /// The DJ's address, and the one claim besides `exp` that is **not**
    /// optional.
    ///
    /// Backend-Service's `definePayload` is `buildJwtPayload(user, …)`
    /// (`shared/authentication/src/jwt-payload.ts`), which spreads
    /// better-auth's user record into the payload; `email` is a required
    /// column there, and the anonymous plugin synthesizes
    /// `temp-<id>@anonymous.wxyc.org` rather than omitting it. So every token
    /// this app can be handed carries one, and a token that doesn't is not a
    /// session this app can represent — decoding it to a `nil` would push
    /// that hole into every caller instead.
    ///
    /// Two costs, both accepted. A token without the claim fails the *whole*
    /// decode (`JWTDecodeError.payloadDecodeFailed`), which on the sign-in
    /// and cold-launch paths is an issue-#53 *transient* JWT-leg failure —
    /// the DJ stays signed in with a pending JWT rather than being kicked
    /// out. And because this type is also the at-rest shape of the issue-#57
    /// offline grace anchor (`TokenSlot.payload`), an anchor persisted
    /// without the claim no longer decodes, costing that install one offline
    /// cold-launch restore; `AuthService.loadPersistedPayload` reads it
    /// through `try?`, so the failure is a fall-through to `.signedOut`, not
    /// a crash.
    ///
    /// `sub` and `role` stay optional, and `role`'s is load-bearing:
    /// `buildJwtPayload` sets it only when the `auth_member` lookup returns a
    /// row, so a DJ with no membership genuinely has no role claim.
    ///
    /// One cross-repo consequence: this is now incompatible with issue #104's
    /// Phase C plan to retire this type via a `typealias` to
    /// `WXYCAuth.JWTClaims`, whose `email` is `String?`. A typealias cannot
    /// narrow optionality, so Phase C has to either keep a local type here or
    /// make the same change upstream — which is safe there for the reason
    /// above, since `wxyc-ios-64` reads only `exp` and its anonymous sessions
    /// carry a synthesized address.
    public let email: String
    public let role: String?
    public let exp: Date

    public var expiration: Date { exp }

    public init(sub: String?, email: String, role: String?, exp: Date) {
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
        email = try c.decode(String.self, forKey: .email)
        role = try c.decodeIfPresent(String.self, forKey: .role)
        let seconds = try c.decode(TimeInterval.self, forKey: .exp)
        exp = Date(timeIntervalSince1970: seconds)
    }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encodeIfPresent(sub, forKey: .sub)
        try c.encode(email, forKey: .email)
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
