//
//  CatalogRowTests.swift
//  WXYCAPITests
//
//  Decoding + rotation-predicate tests for CatalogRow, the GET /library/catalog
//  export DTO (issue #19). Pins BS#1468's exact 14-field projection — including
//  the rotation_kill_date that AlbumSearchResult silently drops — and the
//  client-side rotation-expiry predicate against drift.
//
//  Created by Jake on 06/22/26.
//  Copyright © 2026 WXYC. All rights reserved.
//

import Foundation
import Testing
@testable import WXYCAPI

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
        #expect(row.rotationBin == .heavy)
        // The 14th field — absent from AlbumSearchResult — must survive here.
        #expect(row.rotationKillDate == "2026-07-01")
    }

    @Test func retainsRawRotationKillDate() throws {
        // Regression for the silent-loss bug: reusing AlbumSearchResult drops
        // rotation_kill_date (no such key), so the clone can't tell live
        // rotation from expired. CatalogRow keeps it verbatim as the server's
        // ::text "YYYY-MM-DD" — no Date round-trip, no parser dependence.
        let row = try JSONCoders.decoder.decode(
            CatalogRow.self,
            from: Data(Fixtures.juanaMolinaCatalogRow.utf8)
        )
        #expect(row.rotationKillDate == "2026-07-01")
    }

    @Test func callNumberReusesSharedFormatter() throws {
        // Same shelf-code rendering as AlbumSearchResult (one core entity).
        let row = try JSONCoders.decoder.decode(
            CatalogRow.self,
            from: Data(Fixtures.juanaMolinaCatalogRow.utf8)
        )
        #expect(row.callNumber == "MOL 1/12")
    }

    @Test func toleratesUnknownRotationBin() throws {
        // Raw rotation can carry legacy codes (e.g. 'N') the strict RotationBin
        // enum doesn't model. Decode to nil rather than failing the row.
        let raw = #"{"id":1,"artist_name":"y","album_title":"x","code_letters":"X","code_number":1,"code_artist_number":1,"genre_name":"Rock","format_name":"LP","rotation_bin":"N"}"#
        let row = try JSONCoders.decoder.decode(CatalogRow.self, from: Data(raw.utf8))
        #expect(row.rotationBin == nil)
    }

    @Test func decodesNullRotationFields() throws {
        // An album that has never been in rotation: both fields null.
        let raw = #"{"id":1,"artist_name":"y","album_title":"x","code_letters":"X","code_number":1,"code_artist_number":1,"genre_name":"Rock","format_name":"LP","rotation_bin":null,"rotation_kill_date":null}"#
        let row = try JSONCoders.decoder.decode(CatalogRow.self, from: Data(raw.utf8))
        #expect(row.rotationBin == nil)
        #expect(row.rotationKillDate == nil)
        #expect(row.isInRotation(today: "2026-06-22") == false)
    }

    @Test func roundTripsThroughCodable() throws {
        // The on-device clone (issue #19) persists CatalogRow, so it must
        // encode as well as decode; decode → encode → decode is an equal value.
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

    // MARK: - isInRotation(today:) — raw rotation, client-side expiry

    @Test func inRotationWhenBinSetAndNoKillDate() {
        #expect(makeRow(bin: .heavy, killDate: nil).isInRotation(today: "2026-06-22"))
    }

    @Test func inRotationWhenKillDateInFuture() {
        #expect(makeRow(bin: .medium, killDate: "2026-07-01").isInRotation(today: "2026-06-22"))
    }

    @Test func notInRotationWhenKillDateInPast() {
        #expect(makeRow(bin: .heavy, killDate: "2026-06-01").isInRotation(today: "2026-06-22") == false)
    }

    @Test func notInRotationWhenKillDateIsToday() {
        // Matches the server's `kill_date > CURRENT_DATE` filter (strict
        // greater-than): a record that expires today is already out.
        #expect(makeRow(bin: .heavy, killDate: "2026-06-22").isInRotation(today: "2026-06-22") == false)
    }

    @Test func notInRotationWhenNoBinEvenWithFutureKillDate() {
        #expect(makeRow(bin: nil, killDate: "2027-01-01").isInRotation(today: "2026-06-22") == false)
    }

    // MARK: - localToday formatting

    @Test func localTodayZeroPads() {
        var utc = Calendar(identifier: .gregorian)
        utc.timeZone = TimeZone(identifier: "UTC")!
        let jan5 = utc.date(from: DateComponents(year: 2026, month: 1, day: 5))!
        #expect(CatalogRow.localToday(now: jan5, timeZone: TimeZone(identifier: "UTC")!) == "2026-01-05")
    }

    @Test func localTodayShiftsWithTimeZone() {
        var utc = Calendar(identifier: .gregorian)
        utc.timeZone = TimeZone(identifier: "UTC")!
        // 2026-06-22 00:30 UTC is still 2026-06-21 in US Eastern (UTC-4 in June).
        let instant = utc.date(from: DateComponents(year: 2026, month: 6, day: 22, hour: 0, minute: 30))!
        #expect(CatalogRow.localToday(now: instant, timeZone: TimeZone(identifier: "UTC")!) == "2026-06-22")
        #expect(CatalogRow.localToday(now: instant, timeZone: TimeZone(identifier: "America/New_York")!) == "2026-06-21")
    }

    // MARK: - Helpers

    private func makeRow(bin: RotationBin?, killDate: String?) -> CatalogRow {
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
            rotationKillDate: killDate
        )
    }
}
