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
        let finalClientState = watermark.map { Data($0.utf8) } ?? Data()
        // Page the store so the reindex never materializes the whole catalog and
        // the store stays free for deep-link lookups between pages. Each page is
        // its OWN bounded batch: Core Spotlight caps a single beginBatch/endBatch
        // cycle at 32,767 items, so accumulating the whole catalog into one batch
        // throws -1001 at endBatch. `chunkSize` (≤ 32,767) keeps every batch legal.
        //
        // The watermark must advance only when the WHOLE reindex completes, so it
        // rides the final batch alone and intermediate batches commit empty client
        // state — a crash between batches then leaves `indexedWatermark()`
        // un-advanced and the next refresh re-attempts (the step-4 crash-safety
        // invariant). The last page is held back so the final batch always carries
        // real index work plus the watermark and the vanished-id deletes.
        var cursor: Int? = nil
        var heldPage: [CatalogRow]? = nil
        while true {
            let page = try await store.rows(after: cursor, limit: chunkSize)
            guard let lastID = page.last?.id else { break }
            if let intermediate = heldPage {
                index.beginBatch()
                try await index.indexItems(intermediate.map(CatalogSpotlight.searchableItem(for:)))
                try await index.endBatch(clientState: Data())
            }
            heldPage = page
            cursor = lastID
        }
        // Final batch: the held-back last page (if any) + targeted deletes for
        // vanished ids only — never delete-by-domain, so home-screen search is
        // never emptied mid-reindex — committing the real watermark exactly once.
        index.beginBatch()
        if let lastPage = heldPage {
            try await index.indexItems(lastPage.map(CatalogSpotlight.searchableItem(for:)))
        }
        if !removedIDs.isEmpty {
            try await index.deleteItems(withIdentifiers: removedIDs.map(CatalogSpotlight.itemIdentifier))
        }
        try await index.endBatch(clientState: finalClientState)
    }
}
