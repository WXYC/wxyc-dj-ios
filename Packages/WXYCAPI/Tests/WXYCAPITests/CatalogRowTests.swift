//
//  CatalogRowTests.swift
//  WXYCAPITests
//
//  Decoding + rotation-predicate tests for CatalogRow, the GET /library/catalog
//  export DTO (issue #19). Pins BS#1468's exact 14-field projection — including
//  the rotation_kill_date that AlbumSearchResult silently drops — the tolerant
//  decode of dirty/raw fields, and the client-side rotation-expiry predicate.
//
//  Created by Jake on 06/22/26.
//  Copyright © 2026 WXYC. All rights reserved.
//

import Foundation
import Testing
@testable import WXYCAPI
import WXYCAPIModels

@Suite("CatalogRow")
struct CatalogRowTests {
    @Test func decodesFullExportRow() throws {
        let row = try JSONCoders.decoder.decode(
            CatalogRow.self,
            from: Data(Fixtures.juanaMolinaCatalogRow.utf8)
        )
        #expect(row.id == 100)
        #expect(row.artistName == "Juana Molina")
        #expect(row.albumTitle == "DOGA")
        #expect(row.codeLetters == "MOL")
        #expect(row.codeNumber == 12)
        #expect(row.codeArtistNumber == 1)
        #expect(row.label == "Sonamos")
        #expect(row.genreName == "Rock")
        #expect(row.formatName == "CD")
        #expect(row.onStreaming == true)
        #expect(row.plays == 34)
        #expect(row.artworkURL?.host() == "img.discogs.com")
        #expect(row.rotationBin == "H")
        #expect(row.rotationCohort == .heavy)
        // The 14th field — absent from AlbumSearchResult — must survive here.
        #expect(row.rotationKillDate.day == day("2026-07-01"))
    }

    @Test func narrowsRotationKillDateToTheExpiresCase() throws {
        // Regression for the silent-loss bug: reusing AlbumSearchResult drops
        // rotation_kill_date (no such key), so the clone can't tell live
        // rotation from expired. Asserts the *case*, not just the day, so it
        // complements decodesNullRotationFields's `== .noExpiry` instead of
        // repeating decodesFullExportRow's day assertion verbatim.
        let row = try JSONCoders.decoder.decode(
            CatalogRow.self,
            from: Data(Fixtures.juanaMolinaCatalogRow.utf8)
        )
        #expect(row.rotationKillDate == .expires(day("2026-07-01")))
    }

    @Test func callNumberReusesSharedFormatter() throws {
        // Same shelf-code rendering as AlbumSearchResult (one core entity).
        let row = try JSONCoders.decoder.decode(
            CatalogRow.self,
            from: Data(Fixtures.juanaMolinaCatalogRow.utf8)
        )
        #expect(row.callNumber == "MOL 1/12")
    }

    // MARK: - Dirty / tolerant decode (must not fail the whole row)

    @Test func decodesEmptyArtworkURLAsNil() throws {
        // library.artwork_url is free text; legacy rows hold "" rather than null.
        // An empty/invalid URL must map to nil, NOT throw and drop the row from
        // the full-catalog clone.
        let raw = #"{"id":1,"artist_name":"y","album_title":"x","code_letters":"X","code_number":1,"code_artist_number":1,"genre_name":"Rock","format_name":"LP","artwork_url":""}"#
        let row = try JSONCoders.decoder.decode(CatalogRow.self, from: Data(raw.utf8))
        #expect(row.artworkURL == nil)
        #expect(row.id == 1) // row still decoded
    }

    @Test func decodesNullArtworkURLAsNil() throws {
        let raw = #"{"id":1,"artist_name":"y","album_title":"x","code_letters":"X","code_number":1,"code_artist_number":1,"genre_name":"Rock","format_name":"LP","artwork_url":null}"#
        let row = try JSONCoders.decoder.decode(CatalogRow.self, from: Data(raw.utf8))
        #expect(row.artworkURL == nil)
    }

    @Test func preservesNonCohortRotationBinAndCountsAsInRotation() throws {
        // The fixture value is "N" for historical reasons — it is the bin that
        // motivated this hedge — but it is NOT a current server bin, and this
        // test does not depend on it being one. BS#2173 established it was never
        // a rotation bin and removed it from Backend-Service's freq_enum. What
        // is under test is the general rule: a bin outside the H/M/L/S display
        // cohorts must be preserved RAW, have no display cohort, and count as in
        // rotation per the server predicate (non-null bin = in rotation).
        // Collapsing it to nil (the old enum decode) wrongly reported it out of
        // rotation. Keeping an out-of-cohort literal here is the point of the
        // test; only the claim that the server currently emits one was wrong.
        let raw = #"{"id":1,"artist_name":"y","album_title":"x","code_letters":"X","code_number":1,"code_artist_number":1,"genre_name":"Rock","format_name":"LP","rotation_bin":"N","rotation_kill_date":null}"#
        let row = try JSONCoders.decoder.decode(CatalogRow.self, from: Data(raw.utf8))
        #expect(row.rotationBin == "N")
        #expect(row.rotationCohort == nil)
        #expect(row.isInRotation(today: day("2026-06-22")))
    }

    @Test func emptyRotationBinNormalizesToNilAndIsNotInRotation() throws {
        // A dirty empty-string bin is meaningless — normalized to nil on decode
        // so it reads as "no rotation" (consistent with artwork_url), not wrongly
        // counted as in rotation.
        let raw = #"{"id":1,"artist_name":"y","album_title":"x","code_letters":"X","code_number":1,"code_artist_number":1,"genre_name":"Rock","format_name":"LP","rotation_bin":"","rotation_kill_date":null}"#
        let row = try JSONCoders.decoder.decode(CatalogRow.self, from: Data(raw.utf8))
        #expect(row.rotationBin == nil)
        #expect(row.isInRotation(today: day("2026-06-22")) == false)
    }

    @Test(arguments: ["not-a-date", "", "2026-6-2", "20260622", "twenty-twenty-six", "2026-02-30"])
    func unreadableKillDateFailsClosedRatherThanOpen(killDate: String) throws {
        // The catalog export is the ONLY rotation source that runs in production
        // today — `/library/info` projects no rotation columns at all — so this
        // is the path where a wrong answer actually reaches a DJ's shelf. The
        // behavior was previously pinned only on the `AlbumInfo.Rotation` side,
        // which meant `calendarDay` could be deleted or weakened with CI fully
        // green while dead records silently returned to every shelf.
        //
        // `rotation_kill_date` is held raw (a `::text` cast server-side), so an
        // unreadable value is not rejected at decode. A bare `killDay > today`
        // would then read "not-a-date" as in rotation forever — it sorts above
        // every real "YYYY-MM-DD". Unreadable therefore means expired.
        let raw = """
            {"id":1,"artist_name":"Jessica Pratt","album_title":"On Your Own Love Again",\
            "code_letters":"PRA","code_number":1,"code_artist_number":1,"genre_name":"Rock",\
            "format_name":"LP","rotation_bin":"H","rotation_kill_date":"\(killDate)"}
            """
        let row = try JSONCoders.decoder.decode(CatalogRow.self, from: Data(raw.utf8))
        // The row still decodes — losing rotation must never cost the whole row,
        // which would drop the album from the offline clone entirely.
        #expect(row.albumTitle == "On Your Own Love Again")
        #expect(row.rotationBin == "H")
        #expect(row.isInRotation(today: day("2026-06-22")) == false)
    }

    @Test func killDateAsAFullTimestampStillCompares() throws {
        // The prefix rule, on the live path: a date-time stays comparable against
        // a bare day, so a server that someday widens this column doesn't
        // silently retire every rotation record at once.
        let raw = #"{"id":1,"artist_name":"y","album_title":"x","code_letters":"X","code_number":1,"code_artist_number":1,"genre_name":"Rock","format_name":"LP","rotation_bin":"H","rotation_kill_date":"2026-07-01T20:00:00-04:00"}"#
        let row = try JSONCoders.decoder.decode(CatalogRow.self, from: Data(raw.utf8))
        #expect(row.isInRotation(today: day("2026-06-22")))
        #expect(row.isInRotation(today: day("2026-08-01")) == false)
    }

    @Test func decodesNullRotationFields() throws {
        // An album that has never been in rotation: both fields null.
        let raw = #"{"id":1,"artist_name":"y","album_title":"x","code_letters":"X","code_number":1,"code_artist_number":1,"genre_name":"Rock","format_name":"LP","rotation_bin":null,"rotation_kill_date":null}"#
        let row = try JSONCoders.decoder.decode(CatalogRow.self, from: Data(raw.utf8))
        #expect(row.rotationBin == nil)
        #expect(row.rotationCohort == nil)
        // `.noExpiry`, specifically — not merely "no readable day". A null kill
        // date means the record never expires, the opposite of an unreadable
        // one, and `.day` is nil for both; asserting on the case is
        // what distinguishes them.
        #expect(row.rotationKillDate == .noExpiry)
        #expect(row.rotationKillDate.day == nil)
        #expect(row.isInRotation(today: day("2026-06-22")) == false)
    }

    // MARK: - has_digital_audio (issue #136)

    @Test func decodesHasDigitalAudioTrue() throws {
        let raw = #"{"id":1,"artist_name":"y","album_title":"x","code_letters":"X","code_number":1,"code_artist_number":1,"genre_name":"Rock","format_name":"LP","has_digital_audio":true}"#
        let row = try JSONCoders.decoder.decode(CatalogRow.self, from: Data(raw.utf8))
        #expect(row.hasDigitalAudio == true)
    }

    @Test func absentHasDigitalAudioDecodesToFalse() throws {
        // A Backend that hasn't deployed #2320 yet omits the key entirely; a
        // pre-existing on-disk clone (encoded before this field existed) must
        // still decode as "no digital audio" rather than throwing.
        let raw = #"{"id":1,"artist_name":"y","album_title":"x","code_letters":"X","code_number":1,"code_artist_number":1,"genre_name":"Rock","format_name":"LP"}"#
        let row = try JSONCoders.decoder.decode(CatalogRow.self, from: Data(raw.utf8))
        #expect(row.hasDigitalAudio == false)
    }

    @Test func hasDigitalAudioRoundTripsThroughTheStoreEncoder() throws {
        let original = try JSONCoders.decoder.decode(
            CatalogRow.self,
            from: Data(#"{"id":1,"artist_name":"y","album_title":"x","code_letters":"X","code_number":1,"code_artist_number":1,"genre_name":"Rock","format_name":"LP","has_digital_audio":true}"#.utf8)
        )
        let roundTripped = try JSONCoders.decoder.decode(
            CatalogRow.self,
            from: try JSONCoders.encoder.encode(original)
        )
        #expect(roundTripped.hasDigitalAudio == true)
        #expect(roundTripped == original)
    }

    /// `CatalogRow` ↔ `CatalogExportRow` field-list parity, scoped to `has_digital_audio`
    /// (issue #136 review) rather than a naive full set-equality check: `CatalogRow`
    /// already omits five export fields it deliberately doesn't need
    /// (`legacy_release_id`, `alternate_artist_name`, `album_artist`,
    /// `cross_reference_names`, `popularity` — see the type's own doc comment), so a
    /// bare `Set(CatalogRow.CodingKeys) == Set(CatalogExportRow.CodingKeys)` cannot
    /// pass and never has. What matters for this ticket is that the *new* field made
    /// it across the generation boundary under the same wire key on both sides.
    @Test func hasDigitalAudioKeyMatchesTheGeneratedExportSchema() {
        #expect(CatalogRow.CodingKeys.hasDigitalAudio.stringValue == "has_digital_audio")
        #expect(WXYCAPIModels.CatalogExportRow.CodingKeys.hasDigitalAudio.stringValue == "has_digital_audio")
    }

    @Test func roundTripsThroughCodable() throws {
        // The on-device clone (issue #19) persists CatalogRow, so it must encode
        // as well as decode. decodesFullExportRow (above) guards the wire keys
        // against typos; this guards encode/decode symmetry.
        let original = try JSONCoders.decoder.decode(
            CatalogRow.self,
            from: Data(Fixtures.juanaMolinaCatalogRow.utf8)
        )
        let roundTripped = try JSONCoders.decoder.decode(
            CatalogRow.self,
            from: try JSONCoders.encoder.encode(original)
        )
        #expect(roundTripped == original)
    }

    @Test func roundTripsNonCohortBin() throws {
        // The headline Fix-2 protection: a persisted out-of-cohort bin must
        // survive encode -> decode (the old enum-typed field collapsed it,
        // silently corrupting the clone on reload). "N" is the historical
        // example, not a bin the server emits — see the note above.
        let original = makeRow(bin: "N", killDate: nil)
        let roundTripped = try JSONCoders.decoder.decode(
            CatalogRow.self,
            from: try JSONCoders.encoder.encode(original)
        )
        #expect(roundTripped.rotationBin == "N")
        #expect(roundTripped.isInRotation(today: day("2026-06-22")))
        #expect(roundTripped == original)
    }

    // MARK: - isInRotation core (deterministic local day)

    @Test func inRotationWhenBinSetAndNoKillDate() {
        #expect(makeRow(bin: "H", killDate: nil).isInRotation(today: day("2026-06-22")))
    }

    @Test func inRotationWhenKillDateInFuture() {
        #expect(makeRow(bin: "M", killDate: "2026-07-01").isInRotation(today: day("2026-06-22")))
    }

    @Test func notInRotationWhenKillDateInPast() {
        #expect(makeRow(bin: "H", killDate: "2026-06-01").isInRotation(today: day("2026-06-22")) == false)
    }

    @Test func notInRotationWhenKillDateIsToday() {
        // Matches the server's `kill_date > CURRENT_DATE` filter (strict): a
        // record that expires today is already out.
        #expect(makeRow(bin: "H", killDate: "2026-06-22").isInRotation(today: day("2026-06-22")) == false)
    }

    @Test func notInRotationWhenNoBinEvenWithFutureKillDate() {
        #expect(makeRow(bin: nil, killDate: "2027-01-01").isInRotation(today: day("2026-06-22")) == false)
    }

    @Test func farFutureAndFarPastKillDatesCompareChronologically() {
        // Ordering is over (year, month, day), so this holds regardless of the
        // text's width -- it used to hold only because the padded strings made
        // lexicographic == chronological.
        #expect(makeRow(bin: "H", killDate: "9999-12-31").isInRotation(today: day("2026-06-22")))
        #expect(makeRow(bin: "H", killDate: "0001-01-01").isInRotation(today: day("2026-06-22")) == false)
    }

    // MARK: - isInRotation(asOf:) — public, computes the padded local day itself

    @Test func isInRotationAsOfComputesLocalDay() {
        var utc = Calendar(identifier: .gregorian)
        utc.timeZone = TimeZone(identifier: "UTC")!
        let noonUTC = utc.date(from: DateComponents(year: 2026, month: 6, day: 22, hour: 12))!
        let tz = TimeZone(identifier: "UTC")!
        // kill tomorrow -> in rotation; kill today -> out (strict); past -> out.
        #expect(makeRow(bin: "H", killDate: "2026-06-23").isInRotation(asOf: noonUTC, timeZone: tz))
        #expect(makeRow(bin: "H", killDate: "2026-06-22").isInRotation(asOf: noonUTC, timeZone: tz) == false)
        #expect(makeRow(bin: "H", killDate: nil).isInRotation(asOf: noonUTC, timeZone: tz))
    }

    @Test func isInRotationAsOfRespectsTimeZoneBoundary() {
        var utc = Calendar(identifier: .gregorian)
        utc.timeZone = TimeZone(identifier: "UTC")!
        // 00:30 UTC on the 22nd is still the 21st in America/New_York (EDT, UTC-4).
        let justAfterMidnightUTC = utc.date(from: DateComponents(year: 2026, month: 6, day: 22, hour: 0, minute: 30))!
        let row = makeRow(bin: "H", killDate: "2026-06-22") // expires on the 22nd
        // In UTC, "today" is the 22nd -> kill == today -> out of rotation.
        #expect(row.isInRotation(asOf: justAfterMidnightUTC, timeZone: TimeZone(identifier: "UTC")!) == false)
        // In New York, "today" is still the 21st -> kill (22nd) > today -> in rotation.
        #expect(row.isInRotation(asOf: justAfterMidnightUTC, timeZone: TimeZone(identifier: "America/New_York")!))
    }

    // MARK: - Helpers

    /// `killDate` stays a `"YYYY-MM-DD"` literal so the rotation tables below
    /// read like the wire; `day(_:)` narrows it. Unreadable values are exercised
    /// through the decoder instead (see `unreadableKillDateFailsClosed…`), since
    /// they can only arise on that path.
    private func makeRow(bin: String?, killDate: String?) -> CatalogRow {
        CatalogRow(
            id: 1,
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
            rotationKillDate: killDate.map { day($0) }
        )
    }
}
