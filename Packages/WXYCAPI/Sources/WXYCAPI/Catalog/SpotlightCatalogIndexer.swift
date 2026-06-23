//
//  SpotlightCatalogIndexer.swift
//  WXYCAPI
//
//  Core Spotlight implementation of CatalogIndexing (issue #19 step 3): pages the
//  catalog store into CSSearchableItems, diff-upserts in chunked batches, deletes
//  only vanished ids, and commits the Last-Modified watermark as client state.
//  Gap-free (never delete-by-domain) and off the main actor.
//
//  Created by Jake on 06/23/26.
//  Copyright © 2026 WXYC. All rights reserved.
//

import CoreSpotlight
import Foundation

/// Mirrors the on-device catalog clone into Core Spotlight via the
/// ``SearchableIndexing`` seam, so the work is unit-testable against a fake.
///
/// A `Sendable` value type holding only the (Sendable) index seam and a chunk
/// size; `reindex` is `nonisolated`, so step 4 runs it off the main actor and
/// the first full index never blocks the UI.
public struct SpotlightCatalogIndexer: CatalogIndexing {
    private let index: any SearchableIndexing
    /// Rows per `indexItems` call — bounds memory and lets the index process the
    /// catalog incrementally. Core Spotlight's batch guidance is ~thousands;
    /// injectable so tests can use a small value.
    private let chunkSize: Int

    public init(index: any SearchableIndexing, chunkSize: Int = 5_000) {
        precondition(chunkSize > 0, "chunkSize must be positive")
        self.index = index
        self.chunkSize = chunkSize
    }

    /// Convenience: build an indexer over the live, client-owned
    /// `CSSearchableIndex(name:)` (issue #19 step 5 wiring). Keeps the
    /// `CSSearchableIndex` construction here in `WXYCAPI` alongside
    /// ``RealSearchableIndex`` so the app's composition root needn't import
    /// CoreSpotlight just to wire the index. Defaults to ``CatalogSpotlight/indexName``.
    public init(indexName: String = CatalogSpotlight.indexName, chunkSize: Int = 5_000) {
        self.init(index: RealSearchableIndex(CSSearchableIndex(name: indexName)), chunkSize: chunkSize)
    }

    public func indexedWatermark() async throws -> String? {
        guard let data = try await index.lastClientState(), !data.isEmpty else { return nil }
        return String(data: data, encoding: .utf8)
    }

    public func reindex(store: any CatalogStore, removedIDs: [Int], watermark: String?) async throws {
        index.beginBatch()
        // Page the store so the reindex never materializes the whole catalog and
        // the store stays free for deep-link lookups between pages.
        var cursor: Int? = nil
        while true {
            let page = try await store.rows(after: cursor, limit: chunkSize)
            guard let lastID = page.last?.id else { break }
            try await index.indexItems(page.map(CatalogSpotlight.searchableItem(for:)))
            cursor = lastID
        }
        // Targeted deletes for vanished ids only — never delete-by-domain, so
        // home-screen search is never emptied mid-reindex.
        if !removedIDs.isEmpty {
            try await index.deleteItems(withIdentifiers: removedIDs.map(CatalogSpotlight.itemIdentifier))
        }
        // Commit the watermark exactly once, only after every upsert + delete
        // succeeded. Any throw above leaves the prior client state intact, so
        // `indexedWatermark()` does not advance — the crash-safety property step
        // 4's invariant test relies on. A nil watermark commits empty client
        // state, which `indexedWatermark()` reads back as nil.
        try await index.endBatch(clientState: watermark.map { Data($0.utf8) } ?? Data())
    }
}
