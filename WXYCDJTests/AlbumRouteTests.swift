//
//  AlbumRouteTests.swift
//  WXYCDJTests
//
//  Pins AlbumRoute's id-only value semantics (issue #19 step 6). The route
//  is the single value pushed onto every album NavigationStack path and
//  presented in the cold-launch deep-link cover (step 7), so a clone-hit
//  (fallback-bearing) and a clone-miss (fallback: nil) for the same album
//  must coalesce — both as Equatable and in a NavigationPath/Set — even
//  though AlbumSearchResult's whole-struct Hashable differs across a cloned
//  catalog row and a live search row on addDate/artworkURL/plays.
//
//  Created by Jake on 6/23/26.
//  Copyright © 2026 WXYC. All rights reserved.
//

import Foundation
import Testing
import WXYCAPI
@testable import WXYCDJ

@Suite("AlbumRoute")
struct AlbumRouteTests {
    /// A cloned catalog row and the corresponding live search row carry the
    /// same album but differ field-by-field — the exact whole-struct drift
    /// (addDate/artworkURL/plays) the issue calls out.
    private static func cloneRow(id: Int) -> AlbumSearchResult {
        AlbumSearchResult(id: id, albumTitle: "DOGA", artistName: "Juana Molina")
    }

    private static func liveRow(id: Int) -> AlbumSearchResult {
        AlbumSearchResult(
            id: id,
            addDate: Date(timeIntervalSince1970: 1_700_000_000),
            albumTitle: "DOGA",
            artistName: "Juana Molina",
            plays: 12,
            artworkURL: URL(string: "https://example.com/doga.jpg")
        )
    }

    @Test func cloneHitAndCloneMissCoalesce() {
        let hit = AlbumRoute(id: 42, fallback: Self.cloneRow(id: 42))
        let miss = AlbumRoute(id: 42, fallback: nil)

        #expect(hit == miss)
        #expect(hit.hashValue == miss.hashValue)
    }

    @Test func differingFallbacksWithSameIdAreEqual() {
        let clone = Self.cloneRow(id: 7)
        let live = Self.liveRow(id: 7)
        // Guard the premise: the two rows really are distinct as whole structs,
        // so the equality below is proving id-only keying, not a coincidence.
        #expect(clone != live)

        let cloneRoute = AlbumRoute(id: 7, fallback: clone)
        let liveRoute = AlbumRoute(id: 7, fallback: live)

        #expect(cloneRoute == liveRoute)
        #expect(cloneRoute.hashValue == liveRoute.hashValue)
    }

    @Test func differentIdsAreNotEqual() {
        let a = AlbumRoute(id: 1, fallback: Self.cloneRow(id: 1))
        let b = AlbumRoute(id: 2, fallback: Self.cloneRow(id: 2))

        #expect(a != b)
    }

    @Test func identifiableIdIsAlbumId() {
        let route = AlbumRoute(id: 99, fallback: nil)

        #expect(route.id == 99)
    }

    @Test func setCollapsesRoutesWithSameID() {
        let routes: Set<AlbumRoute> = [
            AlbumRoute(id: 5, fallback: Self.cloneRow(id: 5)),
            AlbumRoute(id: 5, fallback: nil),
            AlbumRoute(id: 5, fallback: Self.liveRow(id: 5)),
        ]

        #expect(routes.count == 1)
    }

    @Test func fallbackIsPreservedForInstantHeaderRender() throws {
        // id-only equality must not discard the payload: the deep-link path
        // reads .fallback to render the header before /library/info returns.
        let row = Self.cloneRow(id: 3)
        let route = AlbumRoute(id: 3, fallback: row)

        let fallback = try #require(route.fallback)
        #expect(fallback.albumTitle == "DOGA")
        #expect(fallback.artistName == "Juana Molina")
    }

    /// Issue #87: BinEntry now decodes the full /djs/bin projection, so a bin
    /// row's route carries a header stand-in via BinEntry.detailFallback
    /// instead of `nil` — the detail header renders instantly, offline
    /// included, instead of awaiting /library/info for an empty view.
    @Test func binRowRoutesAFallbackBearingRoute() throws {
        let entry = try Fixtures.dogaBinEntry()

        let route = AlbumRoute(id: entry.albumId, fallback: entry.detailFallback)

        let fallback = try #require(route.fallback)
        #expect(fallback.albumTitle == "DOGA")
        #expect(fallback.artistName == "Juana Molina")
        #expect(fallback.callNumber == "MOL 1/12")
    }
}
