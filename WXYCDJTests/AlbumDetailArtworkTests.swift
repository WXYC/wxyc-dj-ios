//
//  AlbumDetailArtworkTests.swift
//  WXYCDJTests
//
//  Pins the detail header's artwork precedence: the catalog row is the
//  source of truth, so catalog art (/library/info, then the search-row
//  fallback, then the on-device clone) wins over LML's best-effort metadata
//  art. Regression guard for the "correct cover replaced by the label logo"
//  bug (e.g. Autechre — Confield swapped for the Warp Records logo) — in both
//  its forms: LML landing first, and `/library/info` landing with no
//  `artwork_url` and knocking the search-row cover out of the running.
//
//  Created by Jake on 6/23/26.
//  Copyright © 2026 WXYC. All rights reserved.
//

import Foundation
import Testing
import WXYCAPI
@testable import WXYCDJ

@Suite("AlbumDetail header artwork precedence")
struct AlbumDetailArtworkTests {
    private static let infoArt = URL(string: "https://info.example/confield-cover.jpg")!
    private static let searchArt = URL(string: "https://search.example/confield-cover.jpg")!
    private static let cloneArt = URL(string: "https://clone.example/confield-cover.jpg")!
    private static let lmlArt = URL(string: "https://lml.example/warp-logo.jpg")!

    /// `GET /library/info` — decoded, since `AlbumInfo` has no public memberwise
    /// init. `artworkURL` defaults to **absent**, which is the production shape:
    /// Backend-Service's `getAlbumFromDB` select doesn't project `artwork_url`.
    private static func dogaInfo(artworkURL: URL? = nil) throws -> AlbumInfo {
        let artworkKey = artworkURL.map { ",\n  \"artwork_url\": \"\($0.absoluteString)\"" } ?? ""
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
          "label": "Sonamos"\(artworkKey)
        }
        """
        return try JSONDecoder().decode(AlbumInfo.self, from: Data(json.utf8))
    }

    /// The live search row the DJ tapped — carries `artwork_url` (the search
    /// endpoint projects it), which is why the cover shows in the results list.
    private static func dogaSearchRow(artworkURL: URL? = searchArt) -> AlbumSearchResult {
        AlbumSearchResult(
            id: 100,
            addDate: nil,
            albumTitle: "DOGA",
            artistName: "Juana Molina",
            codeLetters: "MOL",
            codeNumber: 12,
            codeArtistNumber: 1,
            formatName: "CD",
            genreName: "Rock",
            label: "Sonamos",
            labelId: nil,
            rotationBin: nil,
            rotationId: nil,
            plays: 7,
            onStreaming: true,
            albumArtist: nil,
            artworkURL: artworkURL,
            matchedVia: []
        )
    }

    /// The on-device catalog clone, read when `/library/info` fails.
    private static func dogaCloneRow(artworkURL: URL? = cloneArt) -> CatalogRow {
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
            artworkURL: artworkURL,
            rotationBin: "H",
            rotationKillDate: nil
        )
    }

    /// LML enrichment whose `artworkUrl` resolved to a label logo, not the cover.
    private static func labelLogoMetadata() throws -> AlbumMetadata {
        let json = """
        {
          "label": "Sonamos",
          "artworkUrl": "\(lmlArt.absoluteString)"
        }
        """
        return try JSONDecoder().decode(AlbumMetadata.self, from: Data(json.utf8))
    }

    @Test("catalog /library/info art wins over every other source")
    func infoBeatsEverything() throws {
        let url = AlbumDetailView.preferredArtworkURL(
            info: try Self.dogaInfo(artworkURL: Self.infoArt),
            fallback: Self.dogaSearchRow(),
            cloneRow: Self.dogaCloneRow(),
            metadata: try Self.labelLogoMetadata()
        )
        #expect(url == Self.infoArt)
    }

    @Test("search-row art survives /library/info landing without artwork_url")
    func infoWithoutArtworkKeepsSearchRowCover() throws {
        // The reported bug: `/library/info` carries no `artwork_url`, so once it
        // lands the search row must stay in the running — otherwise LML's art
        // (a label logo) visibly replaces the correct cover a beat after push.
        let url = AlbumDetailView.preferredArtworkURL(
            info: try Self.dogaInfo(),
            fallback: Self.dogaSearchRow(),
            cloneRow: nil,
            metadata: try Self.labelLogoMetadata()
        )
        #expect(url == Self.searchArt)
    }

    @Test("search-row fallback art wins over LML metadata art before /library/info lands")
    func fallbackBeatsMetadata() throws {
        let url = AlbumDetailView.preferredArtworkURL(
            info: nil,
            fallback: Self.dogaSearchRow(),
            cloneRow: nil,
            metadata: try Self.labelLogoMetadata()
        )
        #expect(url == Self.searchArt)
    }

    @Test("on-device clone art wins over LML metadata art")
    func cloneBeatsMetadata() throws {
        let url = AlbumDetailView.preferredArtworkURL(
            info: nil,
            fallback: nil,
            cloneRow: Self.dogaCloneRow(),
            metadata: try Self.labelLogoMetadata()
        )
        #expect(url == Self.cloneArt)
    }

    @Test("LML metadata art is used only when the catalog has none")
    func metadataIsLastResort() throws {
        // The Bin → Detail path: no search row, no clone, and `/library/info`
        // carries no art — LML is all that's left, so it renders.
        let url = AlbumDetailView.preferredArtworkURL(
            info: try Self.dogaInfo(),
            fallback: Self.dogaSearchRow(artworkURL: nil),
            cloneRow: Self.dogaCloneRow(artworkURL: nil),
            metadata: try Self.labelLogoMetadata()
        )
        #expect(url == Self.lmlArt)
    }

    // MARK: Reading the clone for artwork

    // The precedence chain only helps if `cloneRow` is actually populated when
    // it's the sole remaining catalog source. It used to be read *only* in
    // `loadInfo()`'s catch, so on every path where `/library/info` succeeded
    // (i.e. all of them, online) the clone leg was unreachable and Bin → Detail
    // — which has no search row at all — still fell through to LML's logo.

    @Test("Bin → Detail (no search row) reads the clone for artwork")
    func noFallbackReadsClone() {
        #expect(AlbumDetailView.shouldReadCloneForArtwork(fallback: nil))
    }

    @Test("a search row without a cover reads the clone for artwork")
    func artlessFallbackReadsClone() {
        #expect(AlbumDetailView.shouldReadCloneForArtwork(fallback: Self.dogaSearchRow(artworkURL: nil)))
    }

    @Test("a search row carrying a cover doesn't need the clone")
    func coveredFallbackSkipsClone() {
        #expect(!AlbumDetailView.shouldReadCloneForArtwork(fallback: Self.dogaSearchRow()))
    }

    @Test("no artwork anywhere yields nil")
    func noneYieldsNil() throws {
        let url = AlbumDetailView.preferredArtworkURL(
            info: try Self.dogaInfo(),
            fallback: nil,
            cloneRow: nil,
            metadata: nil
        )
        #expect(url == nil)
    }
}
