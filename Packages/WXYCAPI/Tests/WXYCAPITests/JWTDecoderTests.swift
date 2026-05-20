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
        #expect(payload.email == "juana@wxyc.org")
        #expect(payload.role == "dj")
        #expect(payload.expiration.timeIntervalSinceNow > 3500)
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
