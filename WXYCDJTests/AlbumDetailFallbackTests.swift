//
//  AlbumDetailFallbackTests.swift
//  WXYCDJTests
//
//  Pins the detail screen's offline catalog-fallback precedence: when
//  GET /library/info fails (the offline case), the header + catalog section
//  fall back to the live search-row `fallback`, then the on-device clone, and
//  the failure is framed as a quiet "saved data" note rather than a red error.
//  Mirrors AlbumDetailArtworkTests — exercises the pure resolver, no rendering.
//
//  Created by Jake on 6/26/26.
//  Copyright © 2026 WXYC. All rights reserved.
//

import Foundation
import Testing
import WXYCAPI
@testable import WXYCDJ

@Suite("AlbumDetail offline catalog fallback")
struct AlbumDetailFallbackTests {
    /// A WXYC-representative cloned catalog row (Juana Molina / DOGA), in heavy
    /// rotation with a display cohort.
    private static func dogaRow(
        rotationBin: String? = "H",
        rotationKillDate: String? = nil
    ) -> CatalogRow {
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
            plays: 7,
            artworkURL: nil,
            rotationBin: rotationBin,
            rotationKillDate: rotationKillDate
        )
    }

    /// A WXYC-representative live search row (Jessica Pratt / On Your Own Love Again).
    private static func prattFallback() -> AlbumSearchResult {
        AlbumSearchResult(
            id: 200,
            addDate: nil,
            albumTitle: "On Your Own Love Again",
            artistName: "Jessica Pratt",
            codeLetters: "PRA",
            codeNumber: 5,
            codeArtistNumber: 1,
            formatName: "LP",
            genreName: "Rock",
            label: "Drag City",
            labelId: nil,
            rotationBin: nil,
            rotationId: nil,
            plays: 3,
            onStreaming: false,
            albumArtist: nil,
            artworkURL: nil,
            matchedVia: []
        )
    }

    /// Decodes a minimal AlbumInfo (no date fields, so a plain decoder suffices).
    private static func dogaInfo() throws -> AlbumInfo {
        let json = """
        {
          "id": 100,
          "album_title": "DOGA",
          "artist_name": "Juana Molina",
          "code_letters": "MOL",
          "code_number": 12,
          "code_artist_number": 1,
          "format_name": "CD",
          "genre_name": "Rock",
          "label": "Sonamos"
        }
        """
        return try JSONDecoder().decode(AlbumInfo.self, from: Data(json.utf8))
    }

    @Test("info present → render from info, no fallback row, no offline note")
    func infoWins() throws {
        let resolution = AlbumDetailView.resolveCatalog(
            info: try Self.dogaInfo(),
            fallback: Self.prattFallback(),
            cloneRow: Self.dogaRow(),
            infoFailed: false
        )
        #expect(resolution.catalogRow == nil)
        #expect(resolution.rotationRow == nil)
        #expect(resolution.note == nil)
    }

    @Test("info nil but not yet failed → live fallback renders un-framed")
    func loadingUsesFallbackWithoutNote() {
        let fallback = Self.prattFallback()
        let resolution = AlbumDetailView.resolveCatalog(
            info: nil,
            fallback: fallback,
            cloneRow: nil,
            infoFailed: false
        )
        #expect(resolution.catalogRow == fallback)
        #expect(resolution.rotationRow == nil)
        #expect(resolution.note == nil)
    }

    @Test("info nil, failed, fallback present → catalog from fallback, saved-data note")
    func failedPrefersFallback() {
        let fallback = Self.prattFallback()
        let clone = Self.dogaRow()
        let resolution = AlbumDetailView.resolveCatalog(
            info: nil,
            fallback: fallback,
            cloneRow: clone,
            infoFailed: true
        )
        #expect(resolution.catalogRow == fallback)
        // Rotation still comes from the raw clone (the live fallback drops the bin).
        #expect(resolution.rotationRow == clone)
        #expect(resolution.note == .savedData)
    }

    @Test("info nil, failed, only clone → catalog from clone, rotation from raw clone, saved-data note")
    func failedFallsBackToClone() {
        let clone = Self.dogaRow()
        let resolution = AlbumDetailView.resolveCatalog(
            info: nil,
            fallback: nil,
            cloneRow: clone,
            infoFailed: true
        )
        #expect(resolution.catalogRow == clone.detailFallback)
        #expect(resolution.rotationRow == clone)
        #expect(resolution.note == .savedData)
        // The bridged catalog row drops the bin; rotation must use the raw clone.
        #expect(resolution.catalogRow?.rotationBin == nil)
        #expect(resolution.rotationRow?.isInRotation() == true)
        #expect(resolution.rotationRow?.rotationCohort == .heavy)
    }

    @Test("info nil, failed, nothing renderable → minimal header, quiet unavailable note")
    func failedWithNothingIsGraceful() {
        let resolution = AlbumDetailView.resolveCatalog(
            info: nil,
            fallback: nil,
            cloneRow: nil,
            infoFailed: true
        )
        #expect(resolution.catalogRow == nil)
        #expect(resolution.rotationRow == nil)
        #expect(resolution.note == .unavailable)
    }

    @Test("clone in rotation via an \"N\" bin reports in-rotation but no display cohort")
    func nonCohortBinStaysInRotation() throws {
        let clone = Self.dogaRow(rotationBin: "N")
        let resolution = AlbumDetailView.resolveCatalog(
            info: nil,
            fallback: nil,
            cloneRow: clone,
            infoFailed: true
        )
        let rotationRow = try #require(resolution.rotationRow)
        // An out-of-cohort bin is still in rotation per the server predicate, but
        // has no H/M/L/S cohort. "N" is the historical fixture value, not a bin
        // the server emits — BS#2173 established it was never a rotation bin.
        #expect(rotationRow.isInRotation() == true)
        #expect(rotationRow.rotationCohort == nil)
        // The clone-only failed render is still framed as saved data.
        #expect(resolution.note == .savedData)
    }

    // MARK: Release-section "Label" dedup (online and offline)

    @Test("LML label is shown only when it differs from the catalog label")
    func metadataLabelShownWhenDiffersFromCatalog() {
        // Online (catalog label from /library/info) and offline (catalog label
        // from the fallback / clone) must dedup against the SAME catalog label —
        // the one the header actually renders — so a matching LML label is never
        // duplicated in the Release section.
        #expect(AlbumDetailView.shouldShowMetadataLabel(
            metadataLabel: "Drag City", catalogLabel: "Sonamos", infoLoaded: true))
        #expect(!AlbumDetailView.shouldShowMetadataLabel(
            metadataLabel: "Sonamos", catalogLabel: "Sonamos", infoLoaded: true))
    }

    @Test("offline: LML label matching the clone label is NOT duplicated")
    func metadataLabelDedupsAgainstCloneOffline() {
        // The regression: offline `info` is nil, so the old `m.label != info?.label`
        // gate compared against nil and always showed the label. With the catalog
        // label sourced from the clone, an identical LML label is suppressed.
        let cloneLabel = Self.dogaRow().label // "Sonamos"
        #expect(!AlbumDetailView.shouldShowMetadataLabel(
            metadataLabel: "Sonamos", catalogLabel: cloneLabel, infoLoaded: true))
    }

    @Test("LML label is withheld until the catalog row has settled")
    func metadataLabelWithheldBeforeInfoLoaded() {
        // Before the catalog row settles we can't know if the LML label diverges,
        // so withhold it to avoid a render-then-collapse flicker.
        #expect(!AlbumDetailView.shouldShowMetadataLabel(
            metadataLabel: "Drag City", catalogLabel: nil, infoLoaded: false))
    }

    @Test("an empty or nil LML label is never shown")
    func emptyMetadataLabelIsNotShown() {
        #expect(!AlbumDetailView.shouldShowMetadataLabel(
            metadataLabel: "", catalogLabel: "Sonamos", infoLoaded: true))
        #expect(!AlbumDetailView.shouldShowMetadataLabel(
            metadataLabel: nil, catalogLabel: "Sonamos", infoLoaded: true))
    }

    @Test("LML label shows when there is no catalog label at all")
    func metadataLabelShownWhenNoCatalogLabel() {
        // No catalog label to dedup against (neither info nor clone carried one),
        // but the row has settled — the LML label is the only label, so show it.
        #expect(AlbumDetailView.shouldShowMetadataLabel(
            metadataLabel: "Drag City", catalogLabel: nil, infoLoaded: true))
    }
}

/// Issue #106: `AlbumDetailView.shouldReportMetadataFailure(_:)` is the pure
/// report/skip decision `loadMetadata`'s catch arm applies. `AlbumDetailView`
/// is a `View` struct with no view-hosting test harness in this repo (every
/// other `AlbumDetail*Tests` suite exercises a pure static helper for exactly
/// this reason), so this is what stands in for driving `loadMetadata` end to
/// end over a stubbed `APIClient`.
@Suite("AlbumDetail metadata-failure reporting")
struct AlbumDetailMetadataReportingTests {
    @Test("a 404 -- no LML match -- is an expected enrichment gap, not reported")
    func notFoundIsNotReported() {
        #expect(!AlbumDetailView.shouldReportMetadataFailure(.http(status: 404, message: nil)))
    }

    @Test("a 429 rate limit is an expected enrichment gap, not reported")
    func rateLimitIsNotReported() {
        #expect(!AlbumDetailView.shouldReportMetadataFailure(.http(status: 429, message: "Too Many Requests")))
    }

    @Test("a decode failure is our own parsing breaking, and is reported")
    func decodingFailureIsReported() {
        #expect(AlbumDetailView.shouldReportMetadataFailure(.decoding(detail: "type mismatch at releaseYear")))
    }

    @Test("unauthorized/notSignedIn are not reported")
    func authFailuresAreNotReported() {
        #expect(!AlbumDetailView.shouldReportMetadataFailure(.unauthorized))
        #expect(!AlbumDetailView.shouldReportMetadataFailure(.notSignedIn))
    }

    /// Issue #106 review Fix 2: being offline is a supported mode on both
    /// the `loadInfo` and `loadMetadata` legs, and they must agree on it —
    /// this is the metadata-leg half of that agreement.
    @Test("offline is a supported mode on both legs, never reported")
    func offlineIsNotReported() {
        #expect(!AlbumDetailView.shouldReportMetadataFailure(.offline(message: "offline")))
    }

    /// A genuine transport defect -- not connectivity, which is `.offline`
    /// now -- is reported on both legs (issue #106 review Fix 2): before the
    /// `.offline` split, `.network` was the "probably just offline" catch-all
    /// this leg withheld; that reasoning stopped applying once `.offline`
    /// took over that meaning on its own.
    @Test("a genuine network defect is reported")
    func networkFailureIsReported() {
        #expect(AlbumDetailView.shouldReportMetadataFailure(.network("Non-HTTP response")))
    }
}
