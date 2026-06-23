//
//  CatalogIndexing.swift
//  WXYCAPI
//
//  The spy-able seam the shared CatalogRefreshService (issue #19 step 4) drives
//  to mirror the on-device catalog store into Core Spotlight. The concrete
//  SpotlightCatalogIndexer lands alongside; step 4 sources its poll watermark
//  from indexedWatermark() so the store is never stranded ahead of the index.
//
//  Created by Jake on 06/23/26.
//  Copyright © 2026 WXYC. All rights reserved.
//

import Foundation

/// Mirrors the on-device catalog clone into Core Spotlight. A `Sendable`
/// protocol so step 4's `CatalogRefreshService` can be tested against a spy and
/// the real Spotlight calls stay injectable.
public protocol CatalogIndexing: Sendable {
    /// The verbatim `Last-Modified` watermark committed with the last successful
    /// reindex, read back from the index's client state; `nil` if the index has
    /// never been populated.
    ///
    /// **Step 4 sources its poll watermark from this, not `store.lastModified()`**:
    /// if a crash leaves the store ahead of the index, the next poll then still
    /// re-attempts the reindex instead of getting a `304` against a watermark the
    /// index never reached.
    func indexedWatermark() async throws -> String?

    /// Mirror `store` into Core Spotlight in one batch: upsert every current row
    /// (paged via `CatalogStore.rows(after:limit:)`), delete the items for
    /// `removedIDs`, and commit `watermark` as the index client state.
    ///
    /// Gap-free: no delete-by-domain, so home-screen search is never emptied
    /// mid-reindex; the upsert is idempotent (stable `uniqueIdentifier`), so a
    /// re-run after an interruption is safe. The watermark is committed only
    /// after every upsert and delete succeed, so a throw leaves the previously
    /// committed watermark intact. Runs off the main actor.
    ///
    /// On a thrown error the Core Spotlight batch is left unended (the framework
    /// has no cancel): the partial upserts persist but the watermark does not
    /// advance, so the next reindex re-runs. Because Core Spotlight forbids a
    /// second open batch before the prior one ends, step 4 must retry on a
    /// freshly-constructed `CSSearchableIndex(name:)` (or the next process
    /// launch), not by re-calling `reindex` on the same failed instance
    /// in-process. A new handle to `CSSearchableIndex.default()` would *not*
    /// clear the dangling batch — it is the shared system index, on which the
    /// batch + client-state API is unsupported anyway, so the indexer must be
    /// driven by a client-owned named index.
    ///
    /// `removedIDs` is supplied by the caller (step 4 diffs the new export
    /// against the previously-indexed id set); this step's tests supply it.
    func reindex(store: any CatalogStore, removedIDs: [Int], watermark: String?) async throws
}
