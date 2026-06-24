//
//  SpotlightCatalogIndexer.swift
//  WXYCAPI
//
//  Core Spotlight implementation of CatalogIndexing. Issue #36: diffs the
//  in-memory export snapshot against the index's own persisted id->fingerprint
//  map (CatalogIndexState, committed as client state), upserts only add/changed
//  rows, deletes only vanished ids, and advances the watermark + map together on
//  the final batch. Upserts and deletes are chunked under Core Spotlight's
//  per-batch cap. Gap-free (never delete-by-domain) and off the main actor.
//
//  Created by Jake on 06/23/26.
//  Copyright © 2026 WXYC. All rights reserved.
//

import CoreSpotlight
import Foundation

/// Mirrors the catalog into Core Spotlight via the ``SearchableIndexing`` seam,
/// so the work is unit-testable against a fake.
///
/// A `Sendable` value type holding only the (Sendable) index seam and a chunk
/// size; `reindex` is `nonisolated`, so step 4 runs it off the main actor and
/// the first full index never blocks the UI.
public struct SpotlightCatalogIndexer: CatalogIndexing {
    private let index: any SearchableIndexing

    /// Core Spotlight's hard cap on the number of items in a single
    /// `beginBatch()`/`endBatch()` cycle (`Int16.max`). A batch holding more than
    /// this throws `CSIndexErrorDomain -1001` at `endBatch`, so `chunkSize` — the
    /// per-batch *combined* upsert + delete count — must stay at or below it.
    public static let maxBatchItemCount = 32_767

    /// Items (upserts **plus** deletes) per batch — bounds memory, lets the index
    /// process the work incrementally, and (capped at ``maxBatchItemCount``) keeps
    /// every batch within Core Spotlight's per-batch limit. Batch guidance is
    /// ~thousands; injectable so tests can use a small value.
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
        // Read ONLY the watermark — `reindex` needs the full map, but every poll
        // and conditional GET hits this, so decoding the whole ~1 MB map here just
        // to read a date string would be wasted work on the cheap-probe path.
        guard let data = try await index.lastClientState(), !data.isEmpty else { return nil }
        return CatalogIndexState.decodeWatermark(from: data)
    }

    /// Decode the index's persisted ``CatalogIndexState`` from client state, or
    /// ``CatalogIndexState/empty`` when the index has never committed (or the blob
    /// is the legacy issue-#19 bare-watermark form, or otherwise unreadable —
    /// `init(decoding:)` is defensive, so an unreadable record degrades to a
    /// from-scratch reindex rather than a crash).
    private func currentState() async throws -> CatalogIndexState {
        guard let data = try await index.lastClientState(), !data.isEmpty,
              let state = CatalogIndexState(decoding: data) else { return .empty }
        return state
    }

    @discardableResult
    public func reindex(snapshot: [CatalogRow], watermark: String?) async throws -> ReindexSummary {
        let oldMap = try await currentState().fingerprints

        // Diff the snapshot against the index's OWN map. Iterating the snapshot
        // (an array) keeps the upsert order deterministic.
        var newMap: [Int: UInt64] = [:]
        newMap.reserveCapacity(snapshot.count)
        var toUpsert: [CatalogRow] = []
        for row in snapshot {
            let fingerprint = CatalogSpotlight.fingerprint(for: row)
            newMap[row.id] = fingerprint
            // Absent (add) or fingerprint differs (change). Equal → skip.
            if oldMap[row.id] != fingerprint {
                toUpsert.append(row)
            }
        }
        // Removes derived from the index's map, NOT the on-device store (which the
        // refresh already replaced) — so they survive a mid-reindex crash and the
        // next run re-derives the identical set. Sorted for deterministic batching.
        let removedIDs = oldMap.keys.filter { newMap[$0] == nil }.sorted()

        // Apply one bounded batch — its upserts, then its deletes — and commit
        // `clientState`. Deletes are by explicit id only (never delete-by-domain),
        // so home-screen search is never emptied mid-reindex.
        func apply(_ batch: Batch, committing clientState: Data) async throws {
            index.beginBatch()
            if !batch.upserts.isEmpty {
                try await index.indexItems(batch.upserts.map(CatalogSpotlight.searchableItem(for:)))
            }
            if !batch.deletes.isEmpty {
                try await index.deleteItems(withIdentifiers: batch.deletes.map(CatalogSpotlight.itemIdentifier))
            }
            try await index.endBatch(clientState: clientState)
        }

        // The watermark and the map advance together, only on the final batch.
        // Each batch commits the map of work applied **so far** (cumulative), not
        // the pre-reindex `oldMap`: a batch's `endBatch` durably applies that
        // batch's upserts/deletes, so committing the cumulative map keeps the
        // persisted record consistent with the physical index *mid-run*. A crash
        // between batches then leaves the committed map describing exactly what the
        // index holds, and the next run reconciles the fresh export against it —
        // re-deleting a now-vanished id rather than stranding it, even if the export
        // changed in the crash window. (Committing `oldMap` instead would, on a
        // first-ever multi-batch index, claim an empty index while batches had
        // already added rows — stranding any that the next export drops.)
        // Intermediate batches withhold the watermark (`nil`) so the next poll
        // re-fetches; only the final batch commits it, atomically with the
        // by-then-complete map (which equals `newMap`). A throw before the final
        // commit leaves the watermark un-advanced, so the next run re-derives.
        let batches = Self.planBatches(upserts: toUpsert, deletes: removedIDs, chunkSize: chunkSize)
        if batches.isEmpty {
            // No add/change/remove (e.g. a 200 that touched only non-fingerprinted
            // fields like `plays`): still commit once so the watermark + map advance
            // and the next poll 304s instead of re-fetching forever. The cumulative
            // map is unchanged, and `newMap == oldMap` here.
            try await apply(Batch(), committing: CatalogIndexState(watermark: watermark, fingerprints: newMap).encode())
        } else {
            var committedMap = oldMap
            for (offset, batch) in batches.enumerated() {
                let isFinal = offset == batches.count - 1
                // Fold this batch's work into the running map BEFORE committing, so
                // the commit reflects the state this batch's endBatch makes durable.
                for row in batch.upserts { committedMap[row.id] = newMap[row.id] }
                for id in batch.deletes { committedMap.removeValue(forKey: id) }
                let state = CatalogIndexState(watermark: isFinal ? watermark : nil, fingerprints: committedMap)
                try await apply(batch, committing: state.encode())
            }
        }

        return ReindexSummary(upserted: toUpsert.count, removed: removedIDs.count)
    }

    /// One bounded unit of work: the upserts and deletes that ride a single Core
    /// Spotlight batch.
    private struct Batch {
        var upserts: [CatalogRow] = []
        var deletes: [Int] = []
    }

    /// Pack `upserts` and `deletes` into batches whose **combined** item count
    /// never exceeds `chunkSize` (both upserts and deletes count against Core
    /// Spotlight's per-batch cap). Upserts fill each batch first, then deletes top
    /// up the remaining capacity. Returns `[]` only when there is no work at all —
    /// the caller still commits one empty final batch to advance the watermark.
    private static func planBatches(upserts: [CatalogRow], deletes: [Int], chunkSize: Int) -> [Batch] {
        var batches: [Batch] = []
        var upsertSlice = upserts[...]
        var deleteSlice = deletes[...]
        while !upsertSlice.isEmpty || !deleteSlice.isEmpty {
            var batch = Batch()
            let takeUpserts = min(upsertSlice.count, chunkSize)
            batch.upserts = Array(upsertSlice.prefix(takeUpserts))
            upsertSlice = upsertSlice.dropFirst(takeUpserts)
            let takeDeletes = min(deleteSlice.count, chunkSize - batch.upserts.count)
            batch.deletes = Array(deleteSlice.prefix(takeDeletes))
            deleteSlice = deleteSlice.dropFirst(takeDeletes)
            batches.append(batch)
        }
        return batches
    }
}
