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

    /// Core Spotlight's hard cap on the number of items in a single
    /// `beginBatch()`/`endBatch()` cycle (`Int16.max`). A batch holding more than
    /// this throws `CSIndexErrorDomain -1001` at `endBatch`, so `chunkSize` — which
    /// is also the per-batch item count — must stay at or below it.
    public static let maxBatchItemCount = 32_767

    /// Rows per `indexItems` call *and* per batch — bounds memory, lets the index
    /// process the catalog incrementally, and (capped at ``maxBatchItemCount``)
    /// keeps every batch within Core Spotlight's per-batch item limit. Batch
    /// guidance is ~thousands; injectable so tests can use a small value.
    private let chunkSize: Int

    public init(index: any SearchableIndexing, chunkSize: Int = 5_000) {
        precondition(
            chunkSize > 0 && chunkSize <= Self.maxBatchItemCount,
            "chunkSize must be in 1...\(Self.maxBatchItemCount) — Core Spotlight's per-batch item cap"
        )
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

        // One bounded batch per `chunkSize` page: Core Spotlight rejects a single
        // beginBatch/endBatch cycle holding more than `maxBatchItemCount` items
        // with -1001 at endBatch, so the whole catalog must never ride one batch.
        //
        // The watermark advances only when the WHOLE reindex completes, so it
        // rides the final batch alone and intermediate batches commit empty client
        // state. A throw between batches therefore CLEARS the committed watermark
        // to empty (so `indexedWatermark()` reads back nil) — it does not leave the
        // prior watermark intact. That is safe because `CatalogRefreshService`
        // replaces the store *before* reindexing, so the next poll re-fetches and
        // re-indexes from scratch rather than 304-ing past a half-built index (the
        // step-4 crash-safety invariant). The last page is held back so the
        // watermark-bearing final batch always carries real index work.

        // Index `page` (when non-empty) and apply `deletedIDs` in one bounded
        // batch, committing `clientState`. Paging the store keeps the reindex from
        // materializing the whole catalog and leaves it free for deep-link lookups
        // between batches; deletes are by explicit id only — never delete-by-domain,
        // so home-screen search is never emptied mid-reindex.
        func commitBatch(_ page: [CatalogRow], clientState: Data, deleting deletedIDs: [Int]) async throws {
            index.beginBatch()
            if !page.isEmpty {
                try await index.indexItems(page.map(CatalogSpotlight.searchableItem(for:)))
            }
            if !deletedIDs.isEmpty {
                try await index.deleteItems(withIdentifiers: deletedIDs.map(CatalogSpotlight.itemIdentifier))
            }
            try await index.endBatch(clientState: clientState)
        }

        var cursor: Int? = nil
        var heldPage: [CatalogRow] = []
        while true {
            let page = try await store.rows(after: cursor, limit: chunkSize)
            guard let lastID = page.last?.id else { break }
            if !heldPage.isEmpty {
                try await commitBatch(heldPage, clientState: Data(), deleting: [])
            }
            heldPage = page
            cursor = lastID
        }
        // Final batch: the held-back last page (empty only for an empty store) plus
        // the vanished-id deletes, committing the real watermark exactly once.
        try await commitBatch(heldPage, clientState: finalClientState, deleting: removedIDs)
    }
}
