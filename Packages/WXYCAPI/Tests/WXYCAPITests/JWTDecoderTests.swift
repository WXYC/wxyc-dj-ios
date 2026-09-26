//
//  JWTDecoderTests.swift
//  WXYCAPITests
//
//  Created by Jake on 5/14/26.
//  Copyright © 2026 WXYC. All rights reserved.
//

import Foundation
import Testing
@testable import WXYCAPI

@Suite("JWTDecoder")
struct JWTDecoderTests {
    @Test func decodesPayloadClaims() throws {
        let token = Fixtures.jwt(expiresIn: 3600)
        let payload = try JWTDecoder.decode(token)
        #expect(payload.sub == "42")
        // Typed `String`, not inferred: this binding stops compiling if
        // `email` is ever relaxed back to `String?`, which is the whole of
        // what the claim's non-optionality buys a caller.
        let email: String = payload.email
        #expect(email == "juana@wxyc.org")
        #expect(payload.role == "dj")
        #expect(payload.expiration.timeIntervalSinceNow > 3500)
    }

    /// `email` is required where `sub` and `role` are not, so a token without
    /// a usable one fails the whole decode rather than yielding a payload with
    /// a hole in it. Both shapes are covered because a claim the server omits
    /// and a claim it sends as `null` are different wire facts that
    /// `decodeIfPresent` used to collapse into the same `nil`.
    @Test(arguments: [
        #"{"sub":"42","role":"dj","exp":1900000000}"#,
        #"{"sub":"42","email":null,"role":"dj","exp":1900000000}"#,
    ])
    func rejectsTokenWithoutUsableEmailClaim(payloadJSON: String) {
        #expect(throws: JWTDecodeError.payloadDecodeFailed) {
            try JWTDecoder.decode(Fixtures.jwt(payloadJSON: payloadJSON))
        }
    }

    /// The claims that stayed optional, pinned so the change to `email`
    /// doesn't quietly travel to its neighbours: `role` is genuinely absent
    /// for a DJ with no `auth_member` row (Backend-Service's `buildJwtPayload`
    /// only sets it when the membership lookup returns one).
    @Test func decodesPayloadWithoutSubOrRole() throws {
        let payload = try JWTDecoder.decode(
            Fixtures.jwt(payloadJSON: #"{"email":"juana@wxyc.org","exp":1900000000}"#)
        )
        #expect(payload.sub == nil)
        #expect(payload.role == nil)
        #expect(payload.email == "juana@wxyc.org")
    }

    @Test func rejectsTokenWithWrongSegmentCount() {
        #expect(throws: JWTDecodeError.malformed) {
            try JWTDecoder.decode("just-one-segment")
        }
    }

    @Test func rejectsTokenWithUndecodablePayload() {
        let bad = "eyJhbGciOiJIUzI1NiJ9.@@@@.sig"
        #expect(throws: (any Error).self) { try JWTDecoder.decode(bad) }
    }
}
