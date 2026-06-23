//
//  CatalogStoreTestSupport.swift
//  WXYCAPITests
//
//  Shared fixtures + temp-store lifecycle for the catalog-store and Spotlight-
//  indexer suites (issue #19): numbered WXYC-representative rows and a unique
//  on-disk SQLite path with full sidecar teardown, so the two suites (both in
//  WXYCAPITests) don't each re-roll them.
//
//  Created by Jake on 06/23/26.
//  Copyright © 2026 WXYC. All rights reserved.
//

import Foundation
@testable import WXYCAPI

/// Test-only helpers shared by ``SQLiteCatalogStoreTests`` and
/// ``SpotlightCatalogIndexerTests``.
enum CatalogStoreTestSupport {
    /// `count` WXYC-representative rows with ascending ids `1...count`. Pass
    /// `shuffled: true` to return them out of order — so an ascending-id result
    /// proves the SELECT orders by id, not by insert order.
    static func numberedRows(_ count: Int, shuffled: Bool = false) -> [CatalogRow] {
        let names = ["Juana Molina", "Jessica Pratt", "Chuquimamani-Condori"]
        let rows = (1...count).map { i in
            CatalogRow(
                id: i, artistName: names[i % names.count], albumTitle: "Album \(i)",
                codeLetters: "AAA", codeNumber: i, codeArtistNumber: 1,
                label: nil, genreName: nil, formatName: nil,
                onStreaming: nil, plays: nil, artworkURL: nil,
                rotationBin: nil, rotationKillDate: nil
            )
        }
        return shuffled ? rows.shuffled() : rows
    }

    /// A fresh, unique temp path for a throwaway catalog database.
    static func tempStoreURL() -> URL {
        FileManager.default.temporaryDirectory
            .appending(path: "catalog-store-test-\(UUID().uuidString).sqlite")
    }

    /// Remove the database and any SQLite sidecar (`-journal`/`-wal`/`-shm` —
    /// hyphen-suffixed on the same path, not a `.journal` path extension).
    static func removeStoreFile(_ url: URL) {
        let fm = FileManager.default
        try? fm.removeItem(at: url)
        let base = url.path(percentEncoded: false)
        for suffix in ["-journal", "-wal", "-shm"] {
            try? fm.removeItem(at: URL(filePath: base + suffix))
        }
    }
}
