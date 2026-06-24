//
//  CatalogIndexing.swift
//  WXYCAPI
//
//  The spy-able seam the shared CatalogRefreshService (issue #19 step 4) drives
//  to mirror the catalog into Core Spotlight. Issue #36 reshapes reindex to take
//  the in-memory export snapshot and derive add/change/remove against the index's
//  own persisted fingerprint map, so removed-id deletes survive a mid-reindex
//  crash and unchanged rows are skipped. The concrete SpotlightCatalogIndexer
//  lands alongside; step 4 sources its poll watermark from indexedWatermark().
//
//  Created by Jake on 06/23/26.
//  Copyright © 2026 WXYC. All rights reserved.
//

import Foundation

/// What one ``CatalogIndexing/reindex(snapshot:watermark:)`` did — the delta the
/// caller logs. With issue #36's per-id diff, both numbers are exact (not the
/// whole catalog): `upserted` is `add ∪ change` and `removed` is the vanished set
/// derived from the index's own map.
public struct ReindexSummary: Equatable, Sendable {
    /// Rows upserted this run — those absent from the index's map (**add**) plus
    /// those present with a differing fingerprint (**change**). Unchanged rows
    /// are skipped and not counted.
    public let upserted: Int
    /// Items deleted this run — ids in the index's map absent from the export.
    public let removed: Int

    public init(upserted: Int, removed: Int) {
        self.upserted = upserted
        self.removed = removed
    }
}

/// Mirrors the catalog into Core Spotlight. A `Sendable` protocol so step 4's
/// `CatalogRefreshService` can be tested against a spy and the real Spotlight
/// calls stay injectable.
public protocol CatalogIndexing: Sendable {
    /// The verbatim `Last-Modified` watermark committed with the last successful
    /// reindex, read back from the index's persisted state; `nil` if the index
    /// has never been populated (or an interrupted reindex withheld it).
    ///
    /// **Step 4 sources its poll watermark from this, not `store.lastModified()`**:
    /// if a crash leaves the store ahead of the index, the next poll then still
    /// re-attempts the reindex instead of getting a `304` against a watermark the
    /// index never reached.
    func indexedWatermark() async throws -> String?

    /// Reconcile Core Spotlight to `snapshot` — the full in-memory `[CatalogRow]`
    /// the refresh just parsed from a `200` — and commit `watermark`.
    ///
    /// The indexer diffs `snapshot` against its **own persisted `id ->
    /// fingerprint` map** (the record of what it last committed, issue #36), not
    /// against the on-device store, which the refresh replaces *before* calling
    /// this. From that diff it derives:
    ///
    /// - **add** — ids in `snapshot` absent from the map → upsert.
    /// - **change** — ids in both whose fingerprint differs → upsert.
    /// - **remove** — ids in the map absent from `snapshot` → delete. Because the
    ///   removed set comes from the index's own map (not the already-replaced
    ///   store), it is reproducible across a mid-reindex crash.
    /// - **unchanged** — equal fingerprint → skipped, so a typical `200` costs
    ///   `O(delta)`.
    ///
    /// Gap-free: deletes are by explicit id only (never delete-by-domain), so
    /// home-screen search is never emptied mid-reindex; upserts are idempotent
    /// (stable `uniqueIdentifier`), so a re-run after an interruption is safe.
    /// Upserts **and** deletes are chunked under Core Spotlight's per-batch item
    /// cap. Runs off the main actor.
    ///
    /// **Crash-safe commit (eventually consistent across runs).** The watermark
    /// advances only on the final batch's commit; a throw leaves it un-advanced, so
    /// the next poll re-fetches and reconciles. Each batch commits the fingerprint
    /// map of work applied **so far** (cumulative), so the persisted map tracks what
    /// the index holds batch by batch — a crash *between* batches leaves the next
    /// run able to reconcile a *fresh* export against what the index actually holds
    /// (re-deleting a vanished id rather than stranding it), not just an unchanged
    /// one. The guarantee is per-run eventual consistency, not per-batch atomicity:
    /// a crash *within* a batch (after its `indexItems`/`deleteItems`, before its
    /// `endBatch`) leaves that batch's work uncommitted to the map, so the next run
    /// re-derives it from the last committed map — a re-upsert is idempotent and a
    /// re-delete a no-op (stable `uniqueIdentifier`). One narrow residual: *if* Core
    /// Spotlight physically persists an unended batch's adds (its `endBatch` is a
    /// client-state checkpoint, not a documented transaction), a row that batch added
    /// but the *next* export drops in the same crash window is in neither the
    /// committed map nor the export, so it lingers as a stale Spotlight item until
    /// that id is next re-added or changed (the gap-free design never deletes by
    /// domain). Self-limiting and far rarer than the between-batch crash, which is
    /// fully reconciled. On a thrown error the open batch is left unended (the
    /// framework has no cancel) and neither the watermark nor the map advances.
    /// Because Core Spotlight forbids a second
    /// open batch before the prior one ends, a retry must run on a
    /// freshly-constructed `CSSearchableIndex(name:)`, not by re-calling `reindex`
    /// on the same failed instance — ``CatalogRefreshService`` guarantees this by
    /// building a fresh indexer per run (its `makeIndexer` factory). A new handle
    /// to `CSSearchableIndex.default()` would *not* clear the dangling batch — it
    /// is the shared system index, on which the batch + client-state API is
    /// unsupported anyway, so the indexer must be driven by a client-owned named
    /// index.
    ///
    /// Returns the ``ReindexSummary`` (upserted + removed counts) for logging.
    @discardableResult
    func reindex(snapshot: [CatalogRow], watermark: String?) async throws -> ReindexSummary
}
