//
//  AlbumInfoRotationTests.swift
//  WXYCAPITests
//
//  Rotation-predicate tests for AlbumInfo.Rotation, the nested rotation block on
//  GET /library/info (issue #93). Pins that it answers "is this in rotation?"
//  with the same rule CatalogRow does — bin presence plus strict kill-date
//  expiry — so the online and offline paths can't give one album two answers.
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

    /// The `CatalogRow` carrying the same rotation state, for the parity tests.
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

    // MARK: - isInRotation core (deterministic local day)

    @Test func inRotationWhenBinSetAndNoKillDate() throws {
        #expect(try makeRotation(bin: "H", killDate: nil).isInRotation(localDay: "2026-06-22"))
    }

    @Test func inRotationWhenKillDateInFuture() throws {
        #expect(try makeRotation(bin: "M", killDate: "2026-07-01").isInRotation(localDay: "2026-06-22"))
    }

    @Test func notInRotationWhenKillDateInPast() throws {
        #expect(try makeRotation(bin: "H", killDate: "2026-06-01").isInRotation(localDay: "2026-06-22") == false)
    }

    @Test func notInRotationWhenKillDateIsToday() throws {
        // Strict, matching the server's `kill_date > CURRENT_DATE` and
        // CatalogRow's compare: a record expiring today is already out.
        #expect(try makeRotation(bin: "H", killDate: "2026-06-22").isInRotation(localDay: "2026-06-22") == false)
    }

    @Test func notInRotationWhenNoBinEvenWithFutureKillDate() throws {
        // The bin is the assignment; a kill date without one is not a rotation.
        #expect(try makeRotation(bin: nil, killDate: "2027-01-01").isInRotation(localDay: "2026-06-22") == false)
    }

    @Test func notInRotationWhenBinIsEmpty() throws {
        // The empty string normalizes to nil on decode, so it reaches the
        // predicate as "no assignment" rather than satisfying the bin guard.
        #expect(try makeRotation(bin: "", killDate: nil).isInRotation(localDay: "2026-06-22") == false)
    }

    @Test func unrecognizedBinIsStillInRotation() throws {
        // Issue #93's hedge, carried through to the predicate: a bin outside the
        // H/M/L/S cohorts has no display cohort but is unambiguously in
        // rotation. Collapsing it to "out" is the failure CatalogRow's raw
        // String? exists to prevent, and this type now shares that posture.
        let rotation = try makeRotation(bin: "N", killDate: nil)
        #expect(rotation.rotationCohort == nil)
        #expect(rotation.isInRotation(localDay: "2026-06-22"))
    }

    @Test func farFutureAndFarPastKillDatesCompareChronologically() throws {
        // The kill date is a parsed Date rendered back to its zero-padded GMT
        // wire day before the lexicographic compare, so the equivalence to a
        // chronological compare holds across the full range.
        #expect(try makeRotation(bin: "H", killDate: "9999-12-31").isInRotation(localDay: "2026-06-22"))
        #expect(try makeRotation(bin: "H", killDate: "0001-01-01").isInRotation(localDay: "2026-06-22") == false)
    }

    // MARK: - isInRotation(asOf:) — public, computes the padded local day itself

    @Test func isInRotationAsOfComputesLocalDay() throws {
        var utc = Calendar(identifier: .gregorian)
        utc.timeZone = TimeZone(identifier: "UTC")!
        let noonUTC = utc.date(from: DateComponents(year: 2026, month: 6, day: 22, hour: 12))!
        let tz = TimeZone(identifier: "UTC")!
        #expect(try makeRotation(bin: "H", killDate: "2026-06-23").isInRotation(asOf: noonUTC, timeZone: tz))
        #expect(try makeRotation(bin: "H", killDate: "2026-06-22").isInRotation(asOf: noonUTC, timeZone: tz) == false)
        #expect(try makeRotation(bin: "H", killDate: nil).isInRotation(asOf: noonUTC, timeZone: tz))
    }

    @Test func isInRotationAsOfRespectsTimeZoneBoundary() throws {
        var utc = Calendar(identifier: .gregorian)
        utc.timeZone = TimeZone(identifier: "UTC")!
        // 00:30 UTC on the 22nd is still the 21st in America/New_York (EDT, UTC-4).
        let justAfterMidnightUTC = utc.date(from: DateComponents(year: 2026, month: 6, day: 22, hour: 0, minute: 30))!
        let rotation = try makeRotation(bin: "H", killDate: "2026-06-22")
        #expect(rotation.isInRotation(asOf: justAfterMidnightUTC, timeZone: TimeZone(identifier: "UTC")!) == false)
        #expect(rotation.isInRotation(asOf: justAfterMidnightUTC, timeZone: TimeZone(identifier: "America/New_York")!))
    }

    @Test func killDateComparesOnItsGMTWireDay() throws {
        // JSONCoders decodes a date-only value to midnight GMT. Rendering it
        // back through anything but GMT would slip it to the previous day on
        // every negative-UTC host (PT/MT/CT/ET) and silently retire a record a
        // day early — the same drift WXYCDateFormatting pins for the render
        // path. A kill date of the 23rd must still be in rotation on the 22nd
        // no matter what the *device* zone is.
        var utc = Calendar(identifier: .gregorian)
        utc.timeZone = TimeZone(identifier: "UTC")!
        let noonPacific = utc.date(from: DateComponents(year: 2026, month: 6, day: 22, hour: 19))!
        let rotation = try makeRotation(bin: "H", killDate: "2026-06-23")
        #expect(rotation.isInRotation(asOf: noonPacific, timeZone: TimeZone(identifier: "America/Los_Angeles")!))
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
        // The load-bearing invariant: rotation reaches the DJ through
        // AlbumInfo.Rotation online and through CatalogRow offline, and the two
        // must never disagree about the same album. Before issue #93's follow-up
        // the online gate was bin-presence alone, so an expired record read as
        // "In rotation" online and was correctly hidden offline.
        let rotation = try makeRotation(bin: bin, killDate: killDate)
        let row = makeRow(bin: bin?.isEmpty == true ? nil : bin, killDate: killDate)
        #expect(rotation.isInRotation(localDay: "2026-06-22") == row.isInRotation(localDay: "2026-06-22"))
    }
}
