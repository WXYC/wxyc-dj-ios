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
//  Also pins issue #86: a catalog `artwork_url` that fails to *load* (dead
//  pre-signed CDN URL, purged asset) falls through to the next source
//  instead of leaving the header blank, via the `failedURLs` parameter on
//  `preferredArtworkURL`. The load-bearing distinction is "recorded as
//  failed" vs. "not yet recorded" — `preferredArtworkURL` never sees a
//  loading/pending state, so a source that is merely still fetching is
//  indistinguishable here from one that already succeeded, and the #83
//  invariant (catalog art is never displaced by LML while genuinely
//  in-flight) holds by construction.
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

    // MARK: Issue #86 — a dead catalog URL falls through instead of blanking

    @Test("a failed search-row URL is skipped in favor of the on-device clone")
    func failedFallbackFallsThroughToClone() throws {
        // The search row's cover is dead (expired CDN signature); the clone
        // still resolves, so it must win — precedence among catalog sources
        // is preserved, not abandoned in favor of LML the moment one leg fails.
        //
        // Note this state needs *both* legs populated, which `loadAll` only
        // arranges when `/library/info` failed: `shouldReadCloneForArtwork` is
        // `fallback?.artworkURL == nil`, so a search row that carries any
        // cover (dead or not) suppresses the clone read on the online
        // Search → Detail path, and the fallthrough there lands on LML
        // instead. Harmless in practice — both sources project the same
        // `library.artwork_url` column, so the clone would usually supply the
        // identical dead URL — but the clone leg is not the common path.
        let url = AlbumDetailView.preferredArtworkURL(
            info: nil,
            fallback: Self.dogaSearchRow(),
            cloneRow: Self.dogaCloneRow(),
            metadata: try Self.labelLogoMetadata(),
            failedURLs: [Self.searchArt]
        )
        #expect(url == Self.cloneArt)
    }

    @Test("every catalog source failing falls through to LML as the last resort")
    func allCatalogSourcesFailedFallsThroughToMetadata() throws {
        let url = AlbumDetailView.preferredArtworkURL(
            info: nil,
            fallback: Self.dogaSearchRow(),
            cloneRow: Self.dogaCloneRow(),
            metadata: try Self.labelLogoMetadata(),
            failedURLs: [Self.searchArt, Self.cloneArt]
        )
        #expect(url == Self.lmlArt)
    }

    @Test("a failed info URL falls through to the search-row fallback, not straight to LML")
    func failedInfoFallsThroughToFallbackNotMetadata() throws {
        // Confirms the fallthrough only skips the specific failed URL and
        // keeps walking the existing precedence chain — it doesn't collapse
        // straight to LML the instant the *first* candidate fails.
        let url = AlbumDetailView.preferredArtworkURL(
            info: try Self.dogaInfo(artworkURL: Self.infoArt),
            fallback: Self.dogaSearchRow(),
            cloneRow: nil,
            metadata: try Self.labelLogoMetadata(),
            failedURLs: [Self.infoArt]
        )
        #expect(url == Self.searchArt)
    }

    @Test("a failure is keyed by URL: marking one occurrence skips every source sharing it")
    func failureIsKeyedByURLNotByBool() throws {
        // The search row and the clone both source `artwork_url` from the
        // same underlying column, so a dead URL commonly appears in both. A
        // single failure record for that URL must retire it everywhere it
        // appears in one step, landing straight on LML rather than needing a
        // second AsyncImage attempt against the identical dead URL.
        let url = AlbumDetailView.preferredArtworkURL(
            info: nil,
            fallback: Self.dogaSearchRow(artworkURL: Self.searchArt),
            cloneRow: Self.dogaCloneRow(artworkURL: Self.searchArt),
            metadata: try Self.labelLogoMetadata(),
            failedURLs: [Self.searchArt]
        )
        #expect(url == Self.lmlArt)
    }

    @Test("a failed clone URL cannot mask a working info URL")
    func failedCloneCannotMaskWorkingInfo() throws {
        // If `/library/info` ever starts projecting `artwork_url`, a stale
        // failure recorded against the *clone's* URL must never suppress a
        // healthy `info` URL — failures are scoped to the specific URL that
        // failed, not to "the catalog" as a whole.
        let url = AlbumDetailView.preferredArtworkURL(
            info: try Self.dogaInfo(artworkURL: Self.infoArt),
            fallback: nil,
            cloneRow: Self.dogaCloneRow(),
            metadata: try Self.labelLogoMetadata(),
            failedURLs: [Self.cloneArt]
        )
        #expect(url == Self.infoArt)
    }

    @Test("an empty failure set (still loading) never displaces catalog art with LML")
    func emptyFailureSetKeepsCatalogArt() throws {
        // The #83 invariant, restated for the fallthrough mechanism: nothing
        // has been recorded as failed yet (the image may simply still be
        // loading), so the catalog source must still win over LML. A
        // fallthrough keyed on "not yet succeeded" rather than "recorded as
        // failed" would reintroduce the #83 cover-swap bug.
        let url = AlbumDetailView.preferredArtworkURL(
            info: nil,
            fallback: Self.dogaSearchRow(),
            cloneRow: Self.dogaCloneRow(),
            metadata: try Self.labelLogoMetadata(),
            failedURLs: []
        )
        #expect(url == Self.searchArt)
    }

    @Test("every source failed yields nil, not LML")
    func everySourceFailedYieldsNil() throws {
        let url = AlbumDetailView.preferredArtworkURL(
            info: try Self.dogaInfo(artworkURL: Self.infoArt),
            fallback: Self.dogaSearchRow(),
            cloneRow: Self.dogaCloneRow(),
            metadata: try Self.labelLogoMetadata(),
            failedURLs: [Self.infoArt, Self.searchArt, Self.cloneArt, Self.lmlArt]
        )
        #expect(url == nil)
    }

    // MARK: Issue #86 review — only a failure that indicts the URL retires it

    // Recording is a one-way door (membership is permanent for the view's
    // life), so a connectivity blip must never retire a healthy cover: doing
    // so would hand the header to LML's label logo the moment the network
    // came back, reintroducing the #83 defect on a path with no self-recovery.

    @Test(
        "a connectivity-class failure does not retire the URL",
        arguments: [
            URLError.Code.notConnectedToInternet,
            .networkConnectionLost,
            .timedOut,
            .cannotConnectToHost,
            .cannotFindHost,
            .dnsLookupFailed,
            .secureConnectionFailed,
            .dataNotAllowed,
            .internationalRoamingOff,
            .callIsActive,
            .cancelled,
        ]
    )
    func transientFailuresAreNotRecorded(code: URLError.Code) {
        #expect(AlbumDetailView.shouldRecordArtworkFailure(URLError(code)) == false)
    }

    @Test(
        "a resource-level URLError retires the URL",
        arguments: [
            // What a CDN's 403/404 error page looks like by the time it
            // reaches the image decoder — the expired-signature and
            // purged-asset cases #86 exists to recover from. Classifying
            // every URLError as transient would disable the fallthrough.
            URLError.Code.cannotDecodeContentData,
            .badServerResponse,
            .fileDoesNotExist,
            .resourceUnavailable,
            .badURL,
            .unsupportedURL,
        ]
    )
    func resourceLevelFailuresAreRecorded(code: URLError.Code) {
        #expect(AlbumDetailView.shouldRecordArtworkFailure(URLError(code)))
    }

    @Test("a non-URLError failure retires the URL")
    func nonURLErrorFailuresAreRecorded() {
        // `AsyncImage` surfaces a decode failure that isn't a `URLError` for
        // a body that transferred fine but isn't an image; that indicts the
        // URL, so it must fall through rather than fail safe.
        #expect(AlbumDetailView.shouldRecordArtworkFailure(CocoaError(.fileReadCorruptFile)))
    }
}
