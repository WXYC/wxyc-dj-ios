//
//  CatalogRowDetailFallbackTests.swift
//  WXYCAPITests
//
//  Tests the CatalogRow -> AlbumSearchResult bridge (issue #19 step 2) that the
//  Spotlight deep link uses to render AlbumDetailView's header instantly from
//  the local clone, before /library/info resolves.
//
//  Created by Jake on 06/22/26.
//  Copyright © 2026 WXYC. All rights reserved.
//

import Foundation
import Testing
@testable import WXYCAPI

@Suite("CatalogRow.detailFallback")
struct CatalogRowDetailFallbackTests {
    /// The render-critical fields AlbumDetailView's header actually reads off
    /// `fallback` (AlbumDetailView.swift headerSection / navigationTitle):
    /// albumTitle, artistName, artworkURL, and the call-number legs (via
    /// `label`/`displayLabel`). The bridge carries the rest of the shared
    /// catalog fields too as a safety margin; the detail view re-fetches the
    /// authoritative row from /library/info, so this is lossless *for the
    /// instant header*, not a full round-trip.
    @Test func carriesHeaderFieldsFromCatalogRow() throws {
        let row = try JSONCoders.decoder.decode(
            CatalogRow.self,
            from: Data(Fixtures.juanaMolinaCatalogRow.utf8)
        )

        let fallback = row.detailFallback

        #expect(fallback.id == 100)
        #expect(fallback.albumTitle == "DOGA")
        #expect(fallback.artistName == "Juana Molina")
        #expect(fallback.artworkURL?.host() == "img.discogs.com")
        #expect(fallback.label == "Sonamos")
        // Call-number legs survive so the shelf code renders identically.
        #expect(fallback.codeLetters == "MOL")
        #expect(fallback.codeNumber == 12)
        #expect(fallback.codeArtistNumber == 1)
        #expect(fallback.callNumber == "MOL 1/12")
        // Other shared catalog fields carried along.
        #expect(fallback.formatName == "CD")
        #expect(fallback.genreName == "Rock")
        #expect(fallback.onStreaming == true)
        #expect(fallback.plays == 34)
    }

    @Test func rotationIsNotBridged() throws {
        // rotationBin is deliberately left nil: AlbumSearchResult's H/M/L/S
        // cohort enum can't faithfully carry a raw catalog bin (an out-of-cohort value
        // would collapse to nil and read as out of rotation). Rotation state
        // for a cloned row comes from CatalogRow.isInRotation / rotationCohort,
        // not this bridge — so even a clean cohort bin like "H" is not carried.
        let cohortRow = try JSONCoders.decoder.decode(
            CatalogRow.self,
            from: Data(Fixtures.juanaMolinaCatalogRow.utf8)
        )
        #expect(cohortRow.rotationBin == "H")           // raw row has a bin...
        #expect(cohortRow.detailFallback.rotationBin == nil)  // ...not bridged

        let nonCohortRow = CatalogRow(
            id: 1, artistName: "Chuquimamani-Condori", albumTitle: "Edits",
            codeLetters: "CHU", codeNumber: 3, codeArtistNumber: 1,
            label: "self-released", genreName: "Electronic", formatName: "LP",
            onStreaming: false, plays: 5, artworkURL: nil,
            rotationBin: "N", rotationKillDate: nil
        )
        #expect(nonCohortRow.detailFallback.rotationBin == nil)
    }

    @Test func nilsSearchOnlyAndDroppedFields() throws {
        let row = try JSONCoders.decoder.decode(
            CatalogRow.self,
            from: Data(Fixtures.juanaMolinaCatalogRow.utf8)
        )
        let fallback = row.detailFallback
        // Fields the export projection drops, or that only exist for search.
        #expect(fallback.addDate == nil)
        #expect(fallback.labelId == nil)
        #expect(fallback.rotationId == nil)
        #expect(fallback.albumArtist == nil)
        #expect(fallback.matchedVia.isEmpty)
    }
}
