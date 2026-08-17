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
    private func makeRow(bin: String?, killDate: String?) -> CatalogRow {
        CatalogRow(
            id: 100,
            artistName: "Juana Molina",
            albumTitle: "DOGA",
            codeLetters: "MOL",
            codeNumber: 12,
            codeArtistNumber: 1,
            label: "Sonamos",
            genreName: "Rock",
            formatName: "CD",
            onStreaming: true,
            plays: 34,
            artworkURL: nil,
            rotationBin: bin,
            rotationKillDate: killDate
        )
    }

    // MARK: - The bin reaching the predicate

    @Test func unrecognizedBinIsStillInRotation() throws {
        // Issue #93's hedge, carried through to the predicate: a bin outside the
        // H/M/L/S cohorts has no display cohort but is unambiguously in
        // rotation. Collapsing it to "out" is the failure the raw String? exists
        // to prevent, and this type now shares CatalogRow's posture.
        let rotation = try makeRotation(bin: "N", killDate: nil)
        #expect(rotation.rotationCohort == nil)
        #expect(rotation.isInRotation(localDay: "2026-06-22"))
    }

    @Test func notInRotationWhenBinIsEmpty() throws {
        // The empty string normalizes to nil on decode, so it reaches the
        // predicate as "no assignment" rather than satisfying the bin guard —
        // the tie between the decode normalization and the rotation answer.
        #expect(try makeRotation(bin: "", killDate: nil).isInRotation(localDay: "2026-06-22") == false)
    }

    // MARK: - The kill date, which is a parsed Date here rather than a raw string

    @Test func killDateComparesOnItsGMTWireDay() throws {
        // JSONCoders decodes a date-only value to midnight GMT. Rendering it
        // back through anything but GMT would slip it to the previous day on
        // every negative-UTC host (PT/MT/CT/ET) and retire a record a day early
        // — the same drift WXYCDateFormatting pins for the render path. A kill
        // date of the 23rd must still be in rotation on the 22nd whatever the
        // device zone is.
        var utc = Calendar(identifier: .gregorian)
        utc.timeZone = TimeZone(identifier: "UTC")!
        let eveningUTC = utc.date(from: DateComponents(year: 2026, month: 6, day: 22, hour: 19))!
        let rotation = try makeRotation(bin: "H", killDate: "2026-06-23")
        #expect(rotation.isInRotation(asOf: eveningUTC, timeZone: TimeZone(identifier: "America/Los_Angeles")!))
    }

    @Test func killDateRendersZeroPaddedSoTheCompareStaysChronological() throws {
        // The lexicographic compare is only equivalent to a chronological one
        // while both sides are fixed-width, and this type's side is *rendered*
        // rather than taken verbatim off the wire — so padding is a live
        // property of the round-trip, not a given. A sub-1000 kill year is the
        // case that catches a regression: padded, "0999-01-01" < "2026-06-22"
        // (out of rotation); unpadded, "999-01-01" > "2026-06-22" would flip it
        // to in-rotation.
        #expect(try makeRotation(bin: "H", killDate: "0999-01-01").isInRotation(localDay: "2026-06-22") == false)
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

    // MARK: - Decode leniency asymmetry between the two dates

    @Test func unparseableAddDateCostsTheDateNotTheScreen() throws {
        // add_date is decorative, so a malformed value decodes to nil and the
        // album still renders — the failure class issue #93 exists to close,
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
        #expect(info.rotation?.isInRotation(localDay: "2026-06-22") == true)
    }

    @Test func unparseableKillDateFailsLoudlyRatherThanOpen() throws {
        // The deliberate asymmetry: `try?` on kill_date would decode to nil,
        // read as "no expiry", and leave a dead record in rotation forever. A
        // throw is the safer failure here, so it stays strict.
        let raw = """
            {
              "id": 401,
              "album_title": "Edits",
              "artist_name": "Chuquimamani-Condori",
              "rotation": { "id": 12, "rotation_bin": "H", "kill_date": "not-a-date" }
            }
            """
        #expect(throws: DecodingError.self) {
            try JSONCoders.decoder.decode(AlbumInfo.self, from: Data(raw.utf8))
        }
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
    ])
    func agreesWithCatalogRowOnTheSameRotationState(bin: String?, killDate: String?) throws {
        // Both types now delegate to RotationPredicate, so this can no longer
        // fail by the rule diverging — it guards the *plumbing* instead: that
        // this type feeds the shared rule the same bin and the same day
        // CatalogRow does, across the raw, empty, and unrecognized bins and both
        // sides of the kill-date boundary.
        let rotation = try makeRotation(bin: bin, killDate: killDate)
        let row = makeRow(bin: bin?.isEmpty == true ? nil : bin, killDate: killDate)
        #expect(rotation.isInRotation(localDay: "2026-06-22") == row.isInRotation(localDay: "2026-06-22"))
    }
}
