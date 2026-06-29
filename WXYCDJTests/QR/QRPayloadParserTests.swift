//
//  QRPayloadParserTests.swift
//  WXYCDJTests
//
//  Pins the QR payload parser: accept only https://dj.wxyc.org/auth/device?...
//  with a user_code query parameter; reject everything else.
//
//  Created by Jake on 6/28/26.
//  Copyright © 2026 WXYC. All rights reserved.
//

import Testing
@testable import WXYCDJ
@testable import WXYCAPI

@Suite("QR payload parser")
struct QRPayloadParserTests {
    @Test func acceptsCanonicalURL() throws {
        let code = try QRSignInPayload.parse("https://dj.wxyc.org/auth/device?user_code=DXFP-92QR")
        #expect(code == "DXFP-92QR")
    }

    @Test func acceptsURLWithExtraParams() throws {
        let code = try QRSignInPayload.parse(
            "https://dj.wxyc.org/auth/device?source=qr&user_code=DXFP-92QR&t=1"
        )
        #expect(code == "DXFP-92QR")
    }

    @Test func trimsLeadingTrailingWhitespace() throws {
        let code = try QRSignInPayload.parse(
            "  https://dj.wxyc.org/auth/device?user_code=DXFP-92QR\n"
        )
        #expect(code == "DXFP-92QR")
    }

    @Test func rejectsForeignHost() {
        #expect(throws: QRSignInError.invalidPayload) {
            try QRSignInPayload.parse("https://example.com/auth/device?user_code=DXFP-92QR")
        }
    }

    @Test func rejectsForeignPathOnAcceptedHost() {
        #expect(throws: QRSignInError.invalidPayload) {
            try QRSignInPayload.parse("https://dj.wxyc.org/login?user_code=DXFP-92QR")
        }
    }

    @Test func rejectsHTTP() {
        #expect(throws: QRSignInError.invalidPayload) {
            try QRSignInPayload.parse("http://dj.wxyc.org/auth/device?user_code=DXFP-92QR")
        }
    }

    @Test func rejectsBareUserCode() {
        #expect(throws: QRSignInError.invalidPayload) {
            try QRSignInPayload.parse("DXFP-92QR")
        }
    }

    @Test func rejectsEmptyAndWhitespace() {
        #expect(throws: QRSignInError.invalidPayload) {
            try QRSignInPayload.parse("")
        }
        #expect(throws: QRSignInError.invalidPayload) {
            try QRSignInPayload.parse("   \n\t  ")
        }
    }

    @Test func rejectsURLWithoutUserCode() {
        #expect(throws: QRSignInError.invalidPayload) {
            try QRSignInPayload.parse("https://dj.wxyc.org/auth/device?source=qr")
        }
    }

    @Test func rejectsURLWithEmptyUserCode() {
        #expect(throws: QRSignInError.invalidPayload) {
            try QRSignInPayload.parse("https://dj.wxyc.org/auth/device?user_code=")
        }
    }
}
