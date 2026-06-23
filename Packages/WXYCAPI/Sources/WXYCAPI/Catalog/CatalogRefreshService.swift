//
//  CatalogRefreshService.swift
//  WXYCAPI
//
//  The shared poll -> 304/200 -> store-replace -> Spotlight-reindex flow (issue
//  #19 step 4) the foreground path and both background tasks call. An actor that
//  single-flights overlapping refreshes, so the bulk runs off the main actor, the
//  BGTask layer stays thin, and there is never more than one Spotlight batch open
//  at a time. The load-bearing invariant: the poll watermark is sourced from the
//  index commit, so it advances only after Spotlight endBatch succeeds.
//
//  Created by Jake on 06/23/26.
//  Copyright © 2026 WXYC. All rights reserved.
//

import Foundation

/// Refreshes the on-device catalog clone and its Spotlight index from
/// `GET /library/catalog` (BS#1468), gated by conditional GET so an unchanged
/// catalog is a cheap `304`.
///
/// An `actor` (not a value type) because it must guarantee **no two refreshes
/// run at once**: issue #19 step 5 wires `refresh()` into both the foreground
/// `.task` and a background task, and `RealSearchableIndex`'s `@unchecked
/// Sendable` is sound *only* because "step 4 guarantees no overlapping reindex".
/// Overlapping `refresh()` calls coalesce onto the single in-flight run (see
/// `refresh()`), so concurrent callers never open a second Core Spotlight batch
/// and the `ids()` diff can't race a concurrent `replace`.
///
/// **A fresh indexer per run.** The service builds a new indexer (via the
/// injected `makeIndexer` factory) for each `refresh()` and each `poll()`, never
/// reusing one for the process lifetime. ``CatalogIndexing``'s contract is that a
/// reindex throwing mid-batch leaves a dangling Core Spotlight batch that can
/// only be recovered on a *freshly constructed* `CSSearchableIndex`, never by
/// re-calling `reindex` on the same instance. Step 5 adds **in-process** retries
/// (a scene-activation refresh, the background reindex leg), so a single
/// long-lived indexer would let one mid-batch failure poison every later reindex
/// until the app is relaunched. A fresh indexer per run reads the same persisted
/// client-state watermark (it lives in the named index, not the instance) and
/// recovers on the very next run. It also keeps `poll()`'s watermark read on a
/// *different* instance than any in-flight reindex's open batch.
///
/// **Watermark invariant.** The poll watermark comes from
/// ``CatalogIndexing/indexedWatermark()`` — the index's committed client state —
/// **not** ``CatalogStore/lastModified()``. The store is replaced before the
/// index commits, so if a crash lands between the two, the store is briefly ahead
/// of the index; sourcing the next poll from the index means it re-fetches and
/// re-indexes instead of getting a `304` against a watermark the index never
/// reached. Equivalently: the watermark advances only when `endBatch` succeeds.
public actor CatalogRefreshService {
    /// What one ``refresh()`` did — for logging/telemetry. This does **not** imply
    /// any work was deferred: a `.refreshed` has already replaced the store and
    /// reindexed Spotlight by the time it returns. (The step-5 BGTask split keeps
    /// the heavy work off the ~30 s poll budget with a *separate* cheap poll leg,
    /// not by inspecting this value.)
    public enum Outcome: Equatable, Sendable {
        /// The server answered `304` — the clone and index were already current.
        case upToDate
        /// The server answered `200`; the store was replaced and Spotlight
        /// reindexed. `rowCount` is the new catalog size, `removed` the number of
        /// vanished ids dropped from the index.
        case refreshed(rowCount: Int, removed: Int)
        /// The server answered `200` with an **empty** export. Treated as a
        /// backend anomaly rather than a legitimately empty catalog: the clone is
        /// left untouched and the watermark is not advanced (see ``refresh()``).
        case skippedEmptyExport
    }

    private let client: APIClient
    private let store: any CatalogStore
    /// Builds a fresh indexer per run (see the type's "fresh indexer per run"
    /// note). Production passes `{ SpotlightCatalogIndexer() }`; tests pass a
    /// closure returning a spy (the same instance models the daemon's persisted
    /// client state across handles).
    private let makeIndexer: @Sendable () -> any CatalogIndexing
    /// The single in-flight run, if any. Overlapping callers await this instead of
    /// starting a second pipeline; it is cleared by the run itself (a `defer` in
    /// `performRefresh`), not by any caller's frame, so a cancelled caller can't
    /// free the slot while the run — and its open Spotlight batch — is still going.
    private var inFlight: Task<Outcome, Error>?

    public init(
        client: APIClient,
        store: any CatalogStore,
        makeIndexer: @escaping @Sendable () -> any CatalogIndexing
    ) {
        self.client = client
        self.store = store
        self.makeIndexer = makeIndexer
    }

    /// Run one refresh cycle: poll conditionally, and on a `200` wholesale-replace
    /// the store and diff-reindex Spotlight. Single-flighted — a second call while
    /// one is in flight coalesces onto the first and returns its result, so the
    /// foreground and a background task can both call it without ever overlapping a
    /// Spotlight batch. (A back-to-back call after one completes simply re-polls and
    /// gets a cheap `304`, since the index watermark has advanced.)
    @discardableResult
    public func refresh() async throws -> Outcome {
        if let inFlight {
            return try await inFlight.value
        }
        let task = Task { try await self.performRefresh() }
        inFlight = task
        return try await task.value
    }

    /// A cheap conditional probe for the background app-refresh leg (issue #19
    /// step 5): does the `catalog(ifModifiedSince:)` GET against the index's
    /// committed watermark and reports whether the catalog moved, **without**
    /// replacing the store or reindexing. The `BGAppRefreshTask` poll leg uses
    /// this to decide whether to submit the charging-gated reindex
    /// `BGProcessingTask`, keeping the multi-MB download + ~50k-row decode +
    /// Spotlight reindex off the ~30 s app-refresh budget. On a `200` the
    /// downloaded body is discarded; the reindex leg re-fetches via ``refresh()``
    /// (idempotent — a foreground refresh that already advanced the watermark
    /// makes that re-fetch a cheap `304`).
    ///
    /// `poll()` opens no Spotlight batch and mutates neither the store nor the
    /// index, so it is not single-flighted with ``refresh()``. But it
    /// **short-circuits when a refresh is already in flight**: that refresh will
    /// replace the store and reindex, so the reindex leg has nothing to add, and
    /// skipping also avoids a second client handle reading the named index while
    /// the refresh holds an open batch. A refresh that *starts during* a poll is
    /// rare (the poll runs only in the background app-refresh task, the refresh in
    /// the foreground or the charging-gated reindex leg) and benign — the worst
    /// case is a stale watermark read that yields a redundant conditional GET,
    /// never data corruption.
    ///
    /// **Known cost (tracked as a follow-up).** On a `200` this still pays the
    /// full body download + ~50k-row decode just to return `true`; a body-less
    /// `HEAD`/lightweight probe would avoid it but needs a Backend-Service change.
    public func poll() async throws -> Bool {
        // A refresh in flight already replaces the store and reindexes; the
        // background reindex leg would only duplicate it (and a read here would
        // touch the named index while that refresh's batch is open).
        if inFlight != nil { return false }
        switch try await conditionalFetch(using: makeIndexer()) {
        case .notModified:
            return false
        case .modified:
            return true
        }
    }

    /// The shared conditional-GET head of `poll()`/`performRefresh()`: read the
    /// index's committed watermark and issue the conditional `catalog` fetch. The
    /// watermark comes from the *index* (not `store.lastModified()`) — the
    /// load-bearing crash-safety invariant lives here, in one place.
    private func conditionalFetch(using indexer: any CatalogIndexing) async throws -> CatalogFetchResult {
        let watermark = try await indexer.indexedWatermark()
        return try await client.catalog(ifModifiedSince: watermark)
    }

    private func performRefresh() async throws -> Outcome {
        // Free the slot when THIS run ends (success, throw, or cancellation),
        // keyed to the run's own lifetime rather than the caller's frame.
        defer { inFlight = nil }

        // A fresh indexer for this run (see the type's "fresh indexer per run"
        // note): an in-process retry after a mid-batch failure must not reuse a
        // poisoned Core Spotlight batch.
        let indexer = makeIndexer()
        switch try await conditionalFetch(using: indexer) {
        case .notModified:
            return .upToDate
        case .modified(let rows, let lastModified):
            // Data safety: an empty export is far likelier a transient backend
            // hiccup than a legitimately empty WXYC catalog. Replacing with it
            // would wipe the last-good clone, commit the new watermark, and then
            // `304` forever — a durable, unrecoverable loss. Skip instead; the
            // index watermark is left unadvanced, so the next poll re-checks.
            guard !rows.isEmpty else {
                return .skippedEmptyExport
            }
            // Diff the vanished ids BEFORE the wholesale replace — a plain reindex
            // only upserts, so the indexer needs the explicit removed set to drop
            // albums that left the catalog. `ids()` reads ids only (no row decode).
            //
            // NOTE: the removed set is derived from the store, which `replace`
            // below mutates, so it is not reproducible across a mid-reindex crash
            // (a vanished id can be stranded in Spotlight). The indexer also
            // re-upserts every row rather than just the changed ones. Both stem
            // from the step-3 indexer's store-paging design and are tracked as a
            // follow-up; see the PR description for issue #19 step 4.
            let previousIDs = try await store.ids()
            let newIDs = Set(rows.map(\.id))
            let removedIDs = previousIDs.subtracting(newIDs)
            // Replace the store first so the indexer pages the NEW rows...
            try await store.replace(rows: rows, lastModified: lastModified)
            // ...then commit the index. The watermark advances only when this
            // endBatch succeeds; a throw here leaves indexedWatermark() unchanged,
            // so the next poll re-fetches the same 200 and retries.
            try await indexer.reindex(store: store, removedIDs: Array(removedIDs), watermark: lastModified)
            return .refreshed(rowCount: rows.count, removed: removedIDs.count)
        }
    }
}
