//
//  CatalogSpotlightTests.swift
//  WXYCAPITests
//
//  Tests the Core Spotlight identifier scheme + CatalogRow -> CSSearchableItem
//  mapping (issue #19 step 3): the "album.<id>" round-trip step 7's deep link
//  relies on, and the attribute mapping home-screen search matches against.
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
}
