//
//  GeneratedModelsContractTests.swift
//  WXYCAPITests
//
//  Pins two contracts of the vendored WXYCAPIModels package (issue #75):
//  the device-auth mixed-casing wire contract from issue #64 (verified
//  against the generated types directly, since the DeviceAuth* hand-rolled
//  DTOs and their WXYCAPI call sites live only on the not-yet-merged
//  qr-signin branch — nothing in this app decodes these types on `main`
//  yet), and the unknown-enum-value tolerance the swift6 generator's
//  `enumUnknownDefaultCase` option provides.
//
//  Created by Jake on 8/14/26.
//  Copyright © 2026 WXYC. All rights reserved.
//

import Foundation
import Testing
import WXYCAPIModels

@Suite("Generated WXYCAPIModels contract")
struct GeneratedModelsContractTests {
    // Issue #64: device-auth approve/deny bodies use camelCase `userCode` on
    // the wire; the verify lookup uses snake_case `user_code`. This app
    // deliberately does not use `convertFromSnakeCase` (JSONCoders.swift),
    // so each generated CodingKeys enum must reflect api.yaml's per-field
    // casing literally rather than a single blanket strategy. Confirmed here
    // against the actual vendored `WXYCAPIModels.DeviceAuthApproveRequest` /
    // `DeviceAuthVerifyResponse` — not a hand-rolled duplicate — so this test
    // fails the moment a regen ever normalizes the casing.

    @Test func deviceAuthApproveRequestEncodesUserCodeAsCamelCase() throws {
        let request = DeviceAuthApproveRequest(userCode: "ABCD-1234")
        let data = try JSONEncoder().encode(request)
        let object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(object["userCode"] as? String == "ABCD-1234")
        #expect(object["user_code"] == nil)
    }

    @Test func deviceAuthDenyRequestEncodesUserCodeAsCamelCase() throws {
        let request = DeviceAuthDenyRequest(userCode: "ABCD-1234")
        let data = try JSONEncoder().encode(request)
        let object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(object["userCode"] as? String == "ABCD-1234")
        #expect(object["user_code"] == nil)
    }

    @Test func deviceAuthVerifyResponseDecodesUserCodeAsSnakeCase() throws {
        let raw = """
            { "user_code": "ABCD-1234", "status": "pending" }
            """
        let response = try JSONDecoder().decode(DeviceAuthVerifyResponse.self, from: Data(raw.utf8))
        #expect(response.userCode == "ABCD-1234")
        #expect(response.status == .pending)
    }

    @Test func deviceAuthVerifyResponseRoundTripsThroughCamelCaseKeyRejection() throws {
        // Negative half of the contract: a body using the OTHER casing
        // (camelCase, as approve/deny use) must NOT satisfy the verify
        // response's snake_case `user_code` key. This is what would silently
        // regress if a future regen ever collapsed both endpoints onto one
        // casing convention.
        let wrongCasing = """
            { "userCode": "ABCD-1234", "status": "pending" }
            """
        #expect(throws: (any Error).self) {
            _ = try JSONDecoder().decode(DeviceAuthVerifyResponse.self, from: Data(wrongCasing.utf8))
        }
    }

    // Forward-compat: an unrecognized enum value on the wire decodes to the
    // generator's `unknownDefaultOpenApi` catch-all case instead of throwing
    // (swift6.yaml's `enumUnknownDefaultCase: true`) — the same
    // degrade-don't-throw discipline the hand-rolled decoders in this
    // package use elsewhere (e.g. AlbumSearchResult's tolerant RotationBin
    // handling).

    @Test func unrecognizedDeviceAuthStatusDecodesToUnknownDefaultCase() throws {
        let raw = """
            { "user_code": "ABCD-1234", "status": "revoked" }
            """
        let response = try JSONDecoder().decode(DeviceAuthVerifyResponse.self, from: Data(raw.utf8))
        #expect(response.status == .unknownDefaultOpenApi)
    }
}
