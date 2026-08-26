//
//  CatalogSpotlightTests.swift
//  WXYCAPITests
//
//  Tests the Core Spotlight identifier scheme + CatalogRow -> CSSearchableItem
//  mapping (issue #19 step 3): the "album.<id>" round-trip step 7's deep link
//  relies on, and the attribute mapping home-screen search matches against. Plus
//  the content fingerprint (issue #36) the delta reindex diffs against — stable
//  across calls, sensitive to every searchable field, blind to the rest.
//
//  Created by Jake on 06/23/26.
//  Copyright © 2026 WXYC. All rights reserved.
//

import CoreSpotlight
import Foundation
import Testing
@testable import WXYCAPI
import struct WXYCAPIModels.CalendarDate

@Suite("CatalogSpotlight")
struct CatalogSpotlightTests {
    static func juanaMolina() throws -> CatalogRow {
        try JSONCoders.decoder.decode(
            CatalogRow.self,
            from: Data(Fixtures.catalogNDJSON.split(separator: "\n")[0].utf8)
        )
    }

    @Test func itemIdentifierRoundTripsThroughAlbumID() {
        for id in [1, 100, 999_999] {
            #expect(CatalogSpotlight.albumID(from: CatalogSpotlight.itemIdentifier(id)) == id)
        }
    }

    @Test func albumIDRejectsMalformedIdentifiers() {
        #expect(CatalogSpotlight.albumID(from: "bogus") == nil)
        #expect(CatalogSpotlight.albumID(from: "album.") == nil)
        #expect(CatalogSpotlight.albumID(from: "album.x") == nil)
        #expect(CatalogSpotlight.albumID(from: "album.12.3") == nil)
        #expect(CatalogSpotlight.albumID(from: "track.12") == nil)
        // Int(_:) would accept a leading sign or surrounding whitespace; the
        // parser must reject anything itemIdentifier(_:) never emits.
        #expect(CatalogSpotlight.albumID(from: "album.-5") == nil)
        #expect(CatalogSpotlight.albumID(from: "album.+5") == nil)
        #expect(CatalogSpotlight.albumID(from: "album. 5") == nil)
        #expect(CatalogSpotlight.albumID(from: "album.5 ") == nil)
    }

    // MARK: Continuation-activity parse (step 7 deep link)

    /// Build the `CSSearchableItemActionType` continuation activity the system
    /// hands back when a DJ taps a catalog item in Spotlight.
    private static func spotlightActivity(identifier: String) -> NSUserActivity {
        let activity = NSUserActivity(activityType: CSSearchableItemActionType)
        activity.userInfo = [CSSearchableItemActivityIdentifier: identifier]
        return activity
    }

    @Test func albumIDFromActivityExtractsTheTappedID() {
        let activity = Self.spotlightActivity(identifier: CatalogSpotlight.itemIdentifier(100))
        #expect(CatalogSpotlight.albumID(fromActivity: activity) == 100)
    }

    @Test func albumIDFromActivityRejectsNonContinuationActivity() {
        // A Handoff / browsing activity that isn't a Spotlight item tap.
        let activity = NSUserActivity(activityType: "org.wxyc.dj.browsing")
        activity.userInfo = [CSSearchableItemActivityIdentifier: CatalogSpotlight.itemIdentifier(100)]
        #expect(CatalogSpotlight.albumID(fromActivity: activity) == nil)
    }

    @Test func albumIDFromActivityRejectsMissingOrMalformedIdentifier() {
        #expect(CatalogSpotlight.albumID(fromActivity: NSUserActivity(activityType: CSSearchableItemActionType)) == nil)
        #expect(CatalogSpotlight.albumID(fromActivity: Self.spotlightActivity(identifier: "track.12")) == nil)
    }

    @Test func searchableItemMapsCatalogRowFields() throws {
        let row = try Self.juanaMolina()
        let item = CatalogSpotlight.searchableItem(for: row)

        #expect(item.uniqueIdentifier == "album.100")
        #expect(item.domainIdentifier == "catalog")
        #expect(item.attributeSet.title == "DOGA")
        // displayName must be set alongside title: Core Spotlight on iOS 17+
        // rejects an item with no displayName as an invalid item
        // (CSIndexErrorDomain -1001), which fails the whole index batch.
        #expect(item.attributeSet.displayName == "DOGA")
        #expect(item.attributeSet.artist == "Juana Molina")
        #expect(item.attributeSet.album == "DOGA")
        // contentDescription = artist + shelf call number.
        let description = try #require(item.attributeSet.contentDescription)
        #expect(description.contains("Juana Molina"))
        #expect(description.contains(row.callNumber))
        #expect(!row.callNumber.isEmpty)
        // keywords carry artist, album, label, and call number for recall — the
        // call number must be here (not only in display-only contentDescription)
        // to be matchable by a shelf-code query.
        let keywords = try #require(item.attributeSet.keywords)
        #expect(keywords.contains("Juana Molina"))
        #expect(keywords.contains("DOGA"))
        #expect(keywords.contains("Sonamos"))
        #expect(keywords.contains(row.callNumber))
        // textContent carries the non-album searchable terms (artist, label, call
        // number) into a matched-but-invisible field (#32) — the recall safety net
        // independent of the keywords iOS-17 regression. Album is omitted (it lives
        // in title/displayName).
        let textContent = try #require(item.attributeSet.textContent)
        #expect(textContent.contains("Juana Molina"))
        #expect(textContent.contains("Sonamos"))
        #expect(textContent.contains(row.callNumber))
    }

    @Test func searchableItemOverloadEmbedsThumbnailDataAndKeepsSearchableAttributes() throws {
        let row = try Self.juanaMolina()
        let bytes = Data([0xFF, 0xD8, 0xFF, 0xE0])   // a stand-in JPEG magic prefix
        let item = CatalogSpotlight.searchableItem(for: row, thumbnailData: bytes)

        // The embedded cover bytes Spotlight renders as the result thumbnail (#44).
        #expect(item.attributeSet.thumbnailData == bytes)
        // The overload must not regress the searchable attribute set (cf. #32): a
        // partial item with no displayName/keywords would trip -1001 or lose recall.
        #expect(item.uniqueIdentifier == "album.100")
        #expect(item.attributeSet.title == "DOGA")
        #expect(item.attributeSet.displayName == "DOGA")
        #expect(item.attributeSet.artist == "Juana Molina")
        #expect(item.attributeSet.keywords?.contains("Sonamos") == true)
        // textContent must survive the overload too — #44's lazy thumbnail upsert
        // rebuilds the full item, and dropping textContent would regress #32 recall.
        #expect(item.attributeSet.textContent?.contains("Juana Molina") == true)
    }

    @Test func searchableItemWithoutThumbnailMatchesPureMapping() throws {
        // searchableItem(for:) is the nil overload — same item, no thumbnailData.
        let row = try Self.juanaMolina()
        let plain = CatalogSpotlight.searchableItem(for: row)
        let nilThumb = CatalogSpotlight.searchableItem(for: row, thumbnailData: nil)
        #expect(plain.attributeSet.thumbnailData == nil)
        #expect(nilThumb.attributeSet.thumbnailData == nil)
        #expect(plain.attributeSet.title == nilThumb.attributeSet.title)
        #expect(plain.attributeSet.keywords == nilThumb.attributeSet.keywords)
        #expect(plain.attributeSet.textContent == nilThumb.attributeSet.textContent)
    }

    @Test func searchableItemOmitsLabelKeywordWhenNil() throws {
        let row = CatalogRow(
            id: 300, artistName: "Chuquimamani-Condori", albumTitle: "Edits",
            codeLetters: nil, codeNumber: nil, codeArtistNumber: nil,
            label: nil, genreName: nil, formatName: nil,
            onStreaming: nil, plays: nil, artworkURL: nil,
            rotationBin: nil, rotationKillDate: nil
        )
        let item = CatalogSpotlight.searchableItem(for: row)
        let keywords = try #require(item.attributeSet.keywords)
        #expect(keywords == ["Chuquimamani-Condori", "Edits"])
        // No call number → contentDescription is just the artist.
        #expect(item.attributeSet.contentDescription == "Chuquimamani-Condori")
        // No label, no call number → textContent is just the artist, with no empty
        // fragments or stray separators.
        #expect(item.attributeSet.textContent == "Chuquimamani-Condori")
    }

    @Test func searchableItemTextContentJoinsOnlyNonEmptyTerms() throws {
        // Artist + call number, but no label: textContent is exactly the two present
        // terms with a single space separator — the nil label leaves no gap (#32).
        let row = CatalogRow(
            id: 301, artistName: "Jessica Pratt", albumTitle: "On Your Own Love Again",
            codeLetters: "PRA", codeNumber: 7, codeArtistNumber: 1,
            label: nil, genreName: nil, formatName: nil,
            onStreaming: nil, plays: nil, artworkURL: nil,
            rotationBin: nil, rotationKillDate: nil
        )
        let item = CatalogSpotlight.searchableItem(for: row)
        #expect(item.attributeSet.textContent == "Jessica Pratt \(row.callNumber)")
    }

    // MARK: Content fingerprint (issue #36)

    /// A fully-populated row whose fields can be overridden one at a time, so a
    /// fingerprint test isolates exactly the field under examination.
    static func fingerprintRow(
        id: Int = 100,
        artistName: String = "Juana Molina",
        albumTitle: String = "DOGA",
        codeLetters: String? = "MOL",
        codeNumber: Int? = 12,
        codeArtistNumber: Int? = 1,
        label: String? = "Sonamos",
        genreName: String? = "Rock",
        formatName: String? = "CD",
        onStreaming: Bool? = true,
        plays: Int? = 34,
        artworkURL: URL? = URL(string: "https://img.discogs.com/doga.jpg"),
        rotationBin: String? = "H",
        rotationKillDate: CalendarDate? = day("2026-07-01")
    ) -> CatalogRow {
        CatalogRow(
            id: id, artistName: artistName, albumTitle: albumTitle,
            codeLetters: codeLetters, codeNumber: codeNumber, codeArtistNumber: codeArtistNumber,
            label: label, genreName: genreName, formatName: formatName,
            onStreaming: onStreaming, plays: plays, artworkURL: artworkURL,
            rotationBin: rotationBin, rotationKillDate: rotationKillDate
        )
    }

    @Test func fingerprintIsStableAcrossCalls() {
        // The whole point vs. Hashable: stable within a process AND across launches.
        #expect(CatalogSpotlight.fingerprint(for: Self.fingerprintRow())
            == CatalogSpotlight.fingerprint(for: Self.fingerprintRow()))
    }

    @Test func fingerprintChangesWhenAnySearchableFieldChanges() {
        let base = CatalogSpotlight.fingerprint(for: Self.fingerprintRow())
        #expect(CatalogSpotlight.fingerprint(for: Self.fingerprintRow(artistName: "Juana M.")) != base)
        #expect(CatalogSpotlight.fingerprint(for: Self.fingerprintRow(albumTitle: "DOGA II")) != base)
        #expect(CatalogSpotlight.fingerprint(for: Self.fingerprintRow(codeLetters: "MOX")) != base)
        #expect(CatalogSpotlight.fingerprint(for: Self.fingerprintRow(codeNumber: 13)) != base)
        #expect(CatalogSpotlight.fingerprint(for: Self.fingerprintRow(codeArtistNumber: 2)) != base)
        #expect(CatalogSpotlight.fingerprint(for: Self.fingerprintRow(label: "Crammed Discs")) != base)
        #expect(CatalogSpotlight.fingerprint(for: Self.fingerprintRow(
            artworkURL: URL(string: "https://img.discogs.com/other.jpg"))) != base)
    }

    @Test func fingerprintIgnoresFieldsTheSearchableItemIgnores() {
        // A change confined to a non-searchable field (plays/genre/format/streaming/
        // rotation) produces an identical CSSearchableItem, so it must NOT flip the
        // fingerprint — that is what keeps a play-count bump from re-upserting the row.
        let base = CatalogSpotlight.fingerprint(for: Self.fingerprintRow())
        #expect(CatalogSpotlight.fingerprint(for: Self.fingerprintRow(genreName: "Electronic")) == base)
        #expect(CatalogSpotlight.fingerprint(for: Self.fingerprintRow(formatName: "LP")) == base)
        #expect(CatalogSpotlight.fingerprint(for: Self.fingerprintRow(onStreaming: false)) == base)
        #expect(CatalogSpotlight.fingerprint(for: Self.fingerprintRow(plays: 9_999)) == base)
        #expect(CatalogSpotlight.fingerprint(for: Self.fingerprintRow(rotationBin: "L")) == base)
        #expect(CatalogSpotlight.fingerprint(for: Self.fingerprintRow(rotationKillDate: day("2099-01-01"))) == base)
        // The id is the map KEY, not fingerprinted content — same content, same fp.
        #expect(CatalogSpotlight.fingerprint(for: Self.fingerprintRow(id: 999)) == base)
    }

    @Test func fingerprintDistinguishesNilFromEmptyString() {
        // Over-sensitive on purpose: a nil -> "" change is a redundant (idempotent)
        // re-upsert, whereas conflating them risks missing a real change.
        #expect(CatalogSpotlight.fingerprint(for: Self.fingerprintRow(label: nil))
            != CatalogSpotlight.fingerprint(for: Self.fingerprintRow(label: "")))
    }
}
