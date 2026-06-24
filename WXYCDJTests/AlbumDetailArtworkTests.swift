//
//  AlbumDetailArtworkTests.swift
//  WXYCDJTests
//
//  Pins the detail header's artwork precedence: the catalog row is the
//  source of truth, so catalog art (/library/info, then the search-row
//  fallback) wins over LML's best-effort metadata art. Regression guard for
//  the "correct cover replaced by the label logo once LML returns" bug
//  (e.g. Autechre — Confield swapped for the Warp Records logo).
//
//  Created by Jake on 6/23/26.
//  Copyright © 2026 WXYC. All rights reserved.
//

import Foundation
import Testing
@testable import WXYCDJ

@Suite("AlbumDetail header artwork precedence")
struct AlbumDetailArtworkTests {
    private static let catalog = URL(string: "https://catalog.example/confield-cover.jpg")!
    private static let search = URL(string: "https://search.example/confield-cover.jpg")!
    private static let lml = URL(string: "https://lml.example/warp-logo.jpg")!

    @Test("catalog /library/info art wins over LML metadata art")
    func infoBeatsMetadata() {
        let url = AlbumDetailView.preferredArtworkURL(
            info: Self.catalog, fallback: Self.search, metadata: Self.lml)
        #expect(url == Self.catalog)
    }

    @Test("search-row fallback art wins over LML metadata art before /library/info lands")
    func fallbackBeatsMetadata() {
        let url = AlbumDetailView.preferredArtworkURL(
            info: nil, fallback: Self.search, metadata: Self.lml)
        #expect(url == Self.search)
    }

    @Test("LML metadata art is used only when the catalog has none")
    func metadataIsLastResort() {
        let url = AlbumDetailView.preferredArtworkURL(
            info: nil, fallback: nil, metadata: Self.lml)
        #expect(url == Self.lml)
    }

    @Test("no artwork anywhere yields nil")
    func noneYieldsNil() {
        let url = AlbumDetailView.preferredArtworkURL(
            info: nil, fallback: nil, metadata: nil)
        #expect(url == nil)
    }
}
