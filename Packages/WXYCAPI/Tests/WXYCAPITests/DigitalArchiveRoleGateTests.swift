//
//  DigitalArchiveRoleGateTests.swift
//  WXYCAPITests
//
//  Pins the issue-#145 badge role gate: hide only on a role that
//  case/whitespace-normalizes to "member"; show for every other value,
//  including nil and unrecognized strings. Fail-open is the point (see
//  DigitalArchiveRoleGate's doc comment), so most of these cases assert
//  visibility, not concealment.
//
//  Created by Jake Bromberg on 08/31/26.
//  Copyright © 2026 WXYC. All rights reserved.
//

import Testing
@testable import WXYCAPI

@Suite("DigitalArchiveRoleGate")
struct DigitalArchiveRoleGateTests {
    /// Catches: the `== "member"` comparison being dropped or inverted.
    @Test("member hides the badge")
    func memberHides() {
        #expect(DigitalArchiveRoleGate.hidesDigitalAudioBadge(role: "member") == true)
    }

    /// Catches: `.lowercased()` being dropped from the comparison.
    @Test("case-insensitive member still hides the badge")
    func caseInsensitiveMemberHides() {
        #expect(DigitalArchiveRoleGate.hidesDigitalAudioBadge(role: "Member") == true)
        #expect(DigitalArchiveRoleGate.hidesDigitalAudioBadge(role: "MEMBER") == true)
    }

    /// Catches: `.trimmingCharacters(in: .whitespaces)` being dropped from
    /// the comparison.
    @Test("surrounding whitespace still hides the badge")
    func whitespacePaddedMemberHides() {
        #expect(DigitalArchiveRoleGate.hidesDigitalAudioBadge(role: "  member  ") == true)
    }

    /// Catches: the predicate defaulting to fail-closed (hiding) on `nil`
    /// instead of fail-open. A `nil` role must never hide the badge -- see
    /// the type's doc comment on why the direction is deliberate.
    @Test("nil role never hides the badge")
    func nilRoleShows() {
        #expect(DigitalArchiveRoleGate.hidesDigitalAudioBadge(role: nil) == false)
    }

    /// Catches: a `canonicalizeRole`-style alias table being reintroduced
    /// (e.g. treating "admin"/"owner" as equivalent to "member" instead of
    /// "stationManager"), or the gate over-hiding on any dj+ role.
    @Test("every canonical and aliased dj+ role shows the badge", arguments: [
        "dj",
        "musicDirector",
        "music_director",
        "music-director",
        "stationManager",
        "station_manager",
        "stationmanager",
        "admin",
        "owner",
    ])
    func djAndAboveRolesShow(role: String) {
        #expect(DigitalArchiveRoleGate.hidesDigitalAudioBadge(role: role) == false)
    }

    /// Catches: the predicate hiding on any unrecognized string, i.e.
    /// silently going fail-closed for a role it doesn't understand.
    @Test("an unrecognized role string shows the badge")
    func unrecognizedRoleShows() {
        #expect(DigitalArchiveRoleGate.hidesDigitalAudioBadge(role: "volunteer") == false)
    }

    /// Catches: comparing against the empty string as if it meant "member".
    @Test("empty string shows the badge")
    func emptyStringShows() {
        #expect(DigitalArchiveRoleGate.hidesDigitalAudioBadge(role: "") == false)
    }
}
