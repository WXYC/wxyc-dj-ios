//
//  BinEntryDetailFallbackTests.swift
//  WXYCAPITests
//
//  Tests the BinEntry -> AlbumSearchResult bridge (issue #87) that lets
//  BinView route a fallback-bearing AlbumRoute, mirroring what
//  CatalogRow.detailFallback does for a Spotlight deep link — so
//  AlbumDetailView renders its header instantly from the bin row already on
//  screen instead of an empty view while /library/info is in flight.
//
//  Created by Jake on 08/16/26.
//  Copyright © 2026 WXYC. All rights reserved.
//

import Foundation
import Testing
@testable import WXYCAPI

@Suite("BinEntry.detailFallback")
struct BinEntryDetailFallbackTests {
    /// A WXYC-representative bin row (Juana Molina / DOGA), carrying every
    /// field the `/djs/bin` projection decodes (issue #80).
    private static func dogaEntry() -> BinEntry {
        BinEntry(
            albumId: 100,
            albumTitle: "DOGA",
            artistName: "Juana Molina",
            alphabeticalName: "Molina, Juana",
            label: "Sonamos",
            codeLetters: "MOL",
            codeArtistNumber: 1,
            codeNumber: 12,
            formatName: "CD",
            genreName: "Rock"
        )
    }

    /// The render-critical fields AlbumDetailView's header actually reads off
    /// `fallback`: albumTitle, artistName, and the call-number legs (via
    /// `label`/`displayLabel`). `BinEntry` carries everything the bin
    /// projection decodes; the detail view still re-fetches the authoritative
    /// row from `/library/info`, so this is lossless *for the instant
    /// header*, not a full round-trip.
    @Test func carriesHeaderFieldsFromBinEntry() {
        let fallback = Self.dogaEntry().detailFallback

        #expect(fallback.id == 100)
        #expect(fallback.albumTitle == "DOGA")
        #expect(fallback.artistName == "Juana Molina")
        #expect(fallback.label == "Sonamos")
        #expect(fallback.codeLetters == "MOL")
        #expect(fallback.codeNumber == 12)
        #expect(fallback.codeArtistNumber == 1)
        #expect(fallback.callNumber == "MOL 1/12")
        #expect(fallback.formatName == "CD")
        #expect(fallback.genreName == "Rock")
    }

    /// The bin projection carries no artwork, play count, or rotation data at
    /// all, so the bridge must leave them nil rather than fabricate a value —
    /// AlbumDetailView's header artwork precedence and rotation section
    /// depend on this to keep reading the on-device clone / `/library/info`
    /// as the real backstops instead of silently trusting an absent value.
    @Test func nilsArtworkPlaysRotationAndSearchOnlyFields() {
        let fallback = Self.dogaEntry().detailFallback

        #expect(fallback.artworkURL == nil)
        #expect(fallback.plays == nil)
        #expect(fallback.onStreaming == nil)
        #expect(fallback.rotationBin == nil)
        #expect(fallback.addDate == nil)
        #expect(fallback.labelId == nil)
        #expect(fallback.rotationId == nil)
        #expect(fallback.albumArtist == nil)
        #expect(fallback.matchedVia.isEmpty)
    }

    /// A bin row with unfiled call-number legs (V/A compilations, unfiled
    /// adds) bridges to a fallback whose `callNumber` degrades the same way
    /// `AlbumSearchResult.callNumber` always has — no `Optional()` literals.
    ///
    /// The row's **own** `callNumber` is empty for the same input, which is
    /// what `BinRow` keys on to omit the call-number `Text` entirely: an empty
    /// `Text` is still a laid-out subview, so leaving it in would let the
    /// `HStack`'s spacing indent the format capsule out of line with the
    /// title/artist above it.
    @Test func toleratesMissingCallNumberLegs() {
        let entry = BinEntry(
            albumId: 7,
            albumTitle: "Edits",
            artistName: "Chuquimamani-Condori",
            label: "self-released",
            genreName: "Electronic"
        )

        let fallback = entry.detailFallback

        #expect(entry.callNumber.isEmpty)
        #expect(fallback.codeLetters == nil)
        #expect(fallback.callNumber.isEmpty)
    }
}
