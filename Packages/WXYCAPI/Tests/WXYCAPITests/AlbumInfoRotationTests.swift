//
//  AlbumInfoRotationTests.swift
//  WXYCAPITests
//
//  Rotation-predicate tests for AlbumInfo.Rotation, the nested rotation block on
//  GET /library/info (issue #93). The rule itself lives in RotationPredicate and
//  is pinned once via CatalogRowTests; what's tested here is everything specific
//  to this type — the raw/empty bin reaching the predicate correctly, the parsed
//  Date kill-date being rendered back to its GMT wire day before the compare, and
//  a parity matrix asserting the online and offline paths agree.
//
//  Created by Jake on 08/17/26.
//  Copyright © 2026 WXYC. All rights reserved.
//

import Foundation
import Testing
@testable import WXYCAPI

@Suite("AlbumInfo.Rotation")
struct AlbumInfoRotationTests {
    /// Builds a `Rotation` through the real decode path — it declares
    /// `init(from:)`, which suppresses the synthesized memberwise init, and
    /// exercising the wire path is what these tests want anyway. Omitted
    /// arguments are omitted *keys*, the contract-legal partial shape.
    private func makeRotation(bin: String?, killDate: String?) throws -> AlbumInfo.Rotation {
        var fields = [#""id": 12"#, #""add_date": "2026-06-01""#]
        if let bin { fields.append(#""rotation_bin": "\#(bin)""#) }
        if let killDate { fields.append(#""kill_date": "\#(killDate)""#) }
        let raw = "{ \(fields.joined(separator: ", ")) }"
        return try JSONCoders.decoder.decode(AlbumInfo.Rotation.self, from: Data(raw.utf8))
    }

    /// The `CatalogRow` carrying the same rotation state, for the parity test.
    ///
    /// Built through its **decoder**, not the memberwise init, for the same
    /// reason `makeRotation` is: the parity claim is that the two types agree
    /// end-to-end on a wire value, and each normalizes on decode. Constructing
    /// this one memberwise forced the caller to hand-apply `"" -> nil` first,
    /// which made the test assert parity against a normalization *the test* had
    /// performed — it would have stayed green if `CatalogRow`'s decoder stopped
    /// normalizing at all.
    private func makeRow(bin: String?, killDate: String?) throws -> CatalogRow {
        var fields = [
            #""id": 100"#,
            #""artist_name": "Juana Molina""#,
            #""album_title": "DOGA""#,
        ]
        if let bin { fields.append(#""rotation_bin": "\#(bin)""#) }
        if let killDate { fields.append(#""rotation_kill_date": "\#(killDate)""#) }
        let raw = "{ \(fields.joined(separator: ", ")) }"
        return try JSONCoders.decoder.decode(CatalogRow.self, from: Data(raw.utf8))
    }

    // MARK: - The bin reaching the predicate

    @Test func unrecognizedBinIsStillInRotation() throws {
        // Issue #93's hedge, carried through to the predicate: a bin outside the
        // H/M/L/S cohorts has no display cohort but is unambiguously in
        // rotation. Collapsing it to "out" is the failure the raw String? exists
        // to prevent, and this type now shares CatalogRow's posture.
        let rotation = try makeRotation(bin: "N", killDate: nil)
        #expect(rotation.rotationCohort == nil)
        #expect(rotation.isInRotation(today: day("2026-06-22")))
    }

    @Test func notInRotationWhenBinIsEmpty() throws {
        // The empty string normalizes to nil on decode, so it reaches the
        // predicate as "no assignment" rather than satisfying the bin guard —
        // the tie between the decode normalization and the rotation answer.
        #expect(try makeRotation(bin: "", killDate: nil).isInRotation(today: day("2026-06-22")) == false)
    }

    // MARK: - The kill date, held raw and compared against the client's day

    @Test func killDateIsNotRetiredEarlyOnANegativeUTCHost() throws {
        // Only one side of the compare is derived from a clock now: the kill date
        // is the verbatim wire string, and `today` comes from the device. A kill
        // date of the 23rd must still be in rotation on the 22nd whatever the
        // device zone is — this is the no-early-retirement direction, distinct
        // from `isInRotationAsOfRespectsTheDeviceTimeZone` below, which pins the
        // day boundary itself at an instant where UTC and the device disagree.
        var utc = Calendar(identifier: .gregorian)
        utc.timeZone = TimeZone(identifier: "UTC")!
        let eveningUTC = utc.date(from: DateComponents(year: 2026, month: 6, day: 22, hour: 19))!
        let rotation = try makeRotation(bin: "H", killDate: "2026-06-23")
        #expect(rotation.isInRotation(asOf: eveningUTC, timeZone: TimeZone(identifier: "America/Los_Angeles")!))
    }

    @Test func aZeroPaddedLowKillYearStaysChronological() throws {
        // The lexicographic compare is equivalent to a chronological one only
        // while both sides are fixed-width. The kill date is now taken verbatim,
        // so padding is the server's to get right rather than something this
        // type could regress — but `localDay` still *renders* the other side, and
        // `calendarDay` still has to accept a padded low year rather than
        // rejecting it as malformed. Padded, "0999-01-01" < "2026-06-22" (out of
        // rotation); an unpadded "999-01-01" would sort above and flip it to in.
        #expect(try makeRotation(bin: "H", killDate: "0999-01-01").isInRotation(today: day("2026-06-22")) == false)
        // The shape check must not mistake a valid low year for garbage.
        #expect(RotationPredicate.calendarDay(from: "0999-01-01") == day("0999-01-01"))
    }

    @Test func isInRotationAsOfRespectsTheDeviceTimeZone() throws {
        var utc = Calendar(identifier: .gregorian)
        utc.timeZone = TimeZone(identifier: "UTC")!
        // 00:30 UTC on the 22nd is still the 21st in America/New_York (EDT, UTC-4).
        let justAfterMidnightUTC = utc.date(from: DateComponents(year: 2026, month: 6, day: 22, hour: 0, minute: 30))!
        let rotation = try makeRotation(bin: "H", killDate: "2026-06-22")
        // In UTC, "today" is the 22nd -> kill == today -> out (strict compare).
        #expect(rotation.isInRotation(asOf: justAfterMidnightUTC, timeZone: TimeZone(identifier: "UTC")!) == false)
        // In New York, "today" is still the 21st -> kill (22nd) > today -> in.
        #expect(rotation.isInRotation(asOf: justAfterMidnightUTC, timeZone: TimeZone(identifier: "America/New_York")!))
    }

    // MARK: - Unreadable dates cost the date, never the screen

    @Test func emptyAddDateCostsTheDateNotTheScreen() throws {
        // add_date is decorative, so a dirty empty value normalizes to nil and
        // the album still renders — the failure class issue #93 exists to close,
        // applied to the sibling field.
        let raw = """
            {
              "id": 401,
              "album_title": "Edits",
              "artist_name": "Chuquimamani-Condori",
              "rotation": { "id": 12, "rotation_bin": "H", "add_date": "" }
            }
            """
        let info = try JSONCoders.decoder.decode(AlbumInfo.self, from: Data(raw.utf8))
        #expect(info.rotation?.addDate == nil)
        #expect(info.rotation?.rotationBin == "H")
        #expect(info.rotation?.isInRotation(today: day("2026-06-22")) == true)
    }

    @Test(arguments: ["not-a-date", "", "2026-6-2", "20260622", "twenty-twenty-six"])
    func unreadableKillDateFailsClosedRatherThanOpen(killDate: String) throws {
        // Now that kill_date is held raw rather than decoded, an unreadable value
        // no longer throws — so the safety property the old strict decode bought
        // has to be enforced where the comparison happens. A bare `killDay > today`
        // would read "not-a-date" as in rotation forever (it sorts above every
        // real day), which is the silently-wrong shelf the rule exists to prevent.
        // Unreadable therefore means expired.
        let raw = """
            {
              "id": 401,
              "album_title": "Edits",
              "artist_name": "Chuquimamani-Condori",
              "rotation": { "id": 12, "rotation_bin": "H", "kill_date": "\(killDate)" }
            }
            """
        let info = try JSONCoders.decoder.decode(AlbumInfo.self, from: Data(raw.utf8))
        // The album still decodes — losing rotation must never cost the screen.
        #expect(info.albumTitle == "Edits")
        #expect(info.rotation?.isInRotation(today: day("2026-06-22")) == false)
    }

    @Test func killDateAsAFullTimestampStillCompares() throws {
        // The prefix rule: a date-time is comparable against a bare day without
        // being reinterpreted through a zone, so a projection that someday ships
        // timestamps doesn't silently retire every record.
        let raw = """
            {
              "id": 401,
              "album_title": "Edits",
              "artist_name": "Chuquimamani-Condori",
              "rotation": { "id": 12, "rotation_bin": "H", "kill_date": "2026-07-01T20:00:00-04:00" }
            }
            """
        let info = try JSONCoders.decoder.decode(AlbumInfo.self, from: Data(raw.utf8))
        #expect(info.rotation?.isInRotation(today: day("2026-06-22")) == true)
        #expect(info.rotation?.isInRotation(today: day("2026-08-01")) == false)
    }

    // MARK: - Parity with CatalogRow

    @Test(arguments: [
        ("H", nil as String?),
        ("H", "2026-07-01"),
        ("H", "2026-06-22"),
        ("H", "2026-06-01"),
        ("N", nil),
        ("N", "2026-07-01"),
        (nil as String?, nil as String?),
        (nil, "2027-01-01"),
        ("", nil),
        // Unreadable kill dates — the behavior new in #95, and the case the
        // matrix previously omitted. Both types must fail closed identically.
        ("H", "not-a-date"),
        ("H", ""),
        ("H", "2026-6-2"),
    ])
    func agreesWithCatalogRowOnTheSameRotationState(bin: String?, killDate: String?) throws {
        // Both types delegate to RotationPredicate, so this can no longer fail by
        // the rule diverging — it guards the *plumbing* instead: that each type
        // feeds the shared rule the same bin and the same day, across the raw,
        // empty, and unrecognized bins, both sides of the kill-date boundary, and
        // a kill date neither can read. Both sides are built through their own
        // decoders so each applies its own normalization rather than the test's.
        let rotation = try makeRotation(bin: bin, killDate: killDate)
        let row = try makeRow(bin: bin, killDate: killDate)
        #expect(rotation.isInRotation(today: day("2026-06-22")) == row.isInRotation(today: day("2026-06-22")))
    }
}
