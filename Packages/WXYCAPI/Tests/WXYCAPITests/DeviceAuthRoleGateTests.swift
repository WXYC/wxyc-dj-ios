//
//  DeviceAuthRoleGateTests.swift
//  WXYCAPITests
//
//  Pins DeviceAuthRoleGate: block exactly "member", defer everything else to the server.
//
//  Created by Meira Volk on 10/09/26.
//  Copyright © 2026 WXYC. All rights reserved.
//

import Testing
@testable import WXYCAPI

@Suite("DeviceAuthRoleGate")
struct DeviceAuthRoleGateTests {
    @Test func memberIsBarred() {
        #expect(DeviceAuthRoleGate.isMember(role: "member") == true)
    }

    @Test(arguments: ["dj", "musicDirector", "stationManager"])
    func personnelAreNotMembers(role: String) {
        #expect(DeviceAuthRoleGate.isMember(role: role) == false)
    }

    /// Catches: an allow-list creeping back in. A role added to the server's
    /// `WXYCRoles` must work on the phone without an app release.
    @Test func futureStationRoleIsNotBlocked() {
        #expect(DeviceAuthRoleGate.isMember(role: "engineer") == false)
    }

    /// A missing claim may be a transient lookup failure at mint time, not
    /// non-membership -- the server's live re-read decides.
    @Test func missingRoleClaimIsNotBlocked() {
        #expect(DeviceAuthRoleGate.isMember(role: nil) == false)
    }

    /// The server compares `row.role === 'member'` exactly, so the phone does
    /// too; a variant spelling is the server's to refuse.
    @Test(arguments: ["Member", " member", "MEMBER", ""])
    func onlyTheExactSpellingIsBlocked(role: String) {
        #expect(DeviceAuthRoleGate.isMember(role: role) == false)
    }
}
