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
        rotationKillDate: String? = "2026-07-01"
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
        #expect(CatalogSpotlight.fingerprint(for: Self.fingerprintRow(rotationKillDate: "2099-01-01")) == base)
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
