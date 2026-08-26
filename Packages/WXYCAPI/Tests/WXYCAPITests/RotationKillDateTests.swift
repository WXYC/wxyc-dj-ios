//
//  RotationKillDateTests.swift
//  WXYCAPITests
//
//  The three-state rotation expiry (issue #79): its parse, its round-trip, and
//  the fail-closed asymmetry that is the reason it isn't a CalendarDate?.
//
//  Created by Jake on 08/25/26.
//  Copyright © 2026 WXYC. All rights reserved.
//

import Foundation
import Testing
@testable import WXYCAPI
import struct WXYCAPIModels.CalendarDate

@Suite("RotationKillDate")
struct RotationKillDateTests {
    // MARK: - Narrowing the wire value

    @Test func absentValueIsNoExpiry() {
        #expect(RotationKillDate(wireValue: nil) == .noExpiry)
    }

    @Test func readableDayIsParsed() {
        #expect(RotationKillDate(wireValue: "2026-07-01") == .expires(day("2026-07-01")))
    }

    @Test func timestampNarrowsToItsLeadingDay() {
        // Prefix tolerance, inherited from RotationPredicate.calendarDay: the
        // server has never sent this shape for the column, but AlbumInfo.Rotation
        // is a hedge against a projection that doesn't exist yet, so a timestamp
        // must not read as garbage and retire the record.
        #expect(RotationKillDate(wireValue: "2026-07-01T20:00:00-04:00") == .expires(day("2026-07-01")))
    }

    @Test(arguments: ["not-a-date", "", "2026-6-2", "20260622", "twenty-twenty-six", "2026-02-30"])
    func unparseableValueIsRetainedVerbatim(raw: String) {
        // Verbatim, not normalized away: a client that cannot read the value has
        // no business rewriting it, and it must round-trip back onto the wire.
        // "2026-02-30" is in this list deliberately -- it passes the digit/dash
        // shape check and is rejected by CalendarDate's real-calendar validation.
        #expect(RotationKillDate(wireValue: raw) == .unreadable(raw))
    }

    // MARK: - The asymmetry that motivates the third case

    @Test func absentAndUnreadableAreOppositeAnswers() {
        // Both have a nil `day`, so anything branching on `day` alone would
        // conflate them -- and conflating them is exactly the fail-open bug:
        // absent means in rotation forever, unreadable must read as expired.
        let absent = RotationKillDate(wireValue: nil)
        let unreadable = RotationKillDate(wireValue: "not-a-date")
        #expect(absent.day == nil)
        #expect(unreadable.day == nil)

        let today = day("2026-06-22")
        #expect(RotationPredicate.isInRotation(bin: "H", killDate: absent, today: today))
        #expect(RotationPredicate.isInRotation(bin: "H", killDate: unreadable, today: today) == false)
    }

    @Test func killDateComparisonIsStrict() {
        // Matches the server's `kill_date > CURRENT_DATE`: expiring today is out.
        let today = day("2026-06-22")
        #expect(RotationPredicate.isInRotation(bin: "H", killDate: .expires(day("2026-06-23")), today: today))
        #expect(RotationPredicate.isInRotation(bin: "H", killDate: .expires(day("2026-06-22")), today: today) == false)
        #expect(RotationPredicate.isInRotation(bin: "H", killDate: .expires(day("2026-06-21")), today: today) == false)
    }

    @Test func noBinIsOutOfRotationWhateverTheExpiry() {
        #expect(RotationPredicate.isInRotation(bin: nil, killDate: .expires(day("2099-01-01")), today: day("2026-06-22")) == false)
        #expect(RotationPredicate.isInRotation(bin: nil, killDate: .noExpiry, today: day("2026-06-22")) == false)
    }

    @Test func comparesChronologicallyAcrossTheFullYearRange() {
        // The old rule compared padded strings, where this held only because the
        // fixed width made lexicographic == chronological. CalendarDate orders by
        // (year, month, day), so an unpadded low year can't sort above a high one.
        let today = day("2026-06-22")
        #expect(RotationPredicate.isInRotation(bin: "H", killDate: .expires(day("9999-12-31")), today: today))
        #expect(RotationPredicate.isInRotation(bin: "H", killDate: .expires(day("0001-01-01")), today: today) == false)
        #expect(RotationPredicate.isInRotation(bin: "H", killDate: .expires(day("0999-01-01")), today: today) == false)
    }

    // MARK: - Codable round-trip (this IS the SQLite clone's on-disk format)

    @Test(arguments: [nil, "2026-07-01", "not-a-date"] as [String?])
    func encodesBackToTheBareWireValue(raw: String?) throws {
        // SQLiteCatalogStore persists CatalogRow as a JSON blob, so this encoding
        // is the clone's on-disk format: it must be the bare string (or null),
        // never an enum envelope, or a clone written by one build is unreadable
        // by another.
        let encoded = try JSONCoders.encoder.encode(RotationKillDate(wireValue: raw))
        let expected = raw.map { "\"\($0)\"" } ?? "null"
        #expect(String(decoding: encoded, as: UTF8.self) == expected)
    }

    @Test(arguments: [nil, "2026-07-01", "not-a-date"] as [String?])
    func roundTripsThroughCodable(raw: String?) throws {
        let original = RotationKillDate(wireValue: raw)
        let decoded = try JSONCoders.decoder.decode(
            RotationKillDate.self,
            from: try JSONCoders.encoder.encode(original)
        )
        #expect(decoded == original)
        #expect(decoded.wireValue == raw)
    }

    @Test func decodingNeverThrowsOnADirtyValue() throws {
        // The load-bearing difference from a strict `CalendarDate?`. A throw here
        // would propagate out of CatalogRow and, via APIClient.decodeNDJSON,
        // fail the WHOLE catalog fetch over one bad row -- costing the entire
        // on-device clone refresh instead of one album's rotation badge.
        let decoded = try JSONCoders.decoder.decode(
            RotationKillDate.self,
            from: Data("\"garbage\"".utf8)
        )
        #expect(decoded == .unreadable("garbage"))
    }
}
