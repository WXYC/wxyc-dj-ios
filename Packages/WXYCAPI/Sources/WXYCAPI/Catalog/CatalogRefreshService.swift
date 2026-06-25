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
import OSLog

private let refreshLog = Logger(subsystem: "org.wxyc.dj", category: "catalog")

/// Refreshes the on-device catalog clone and its Spotlight index from
/// `GET /library/catalog` (BS#1468), gated by conditional GET so an unchanged
/// catalog is a cheap `304`.
///
/// An `actor` (not a value type) because it must guarantee **no two index touches
/// run at once**: issue #19 step 5 wires `refresh()` into both the foreground
/// `.task` and a background task, and issue #44 adds the lazy `cacheThumbnail()`
/// upsert as a second writer to the same named index. `RealSearchableIndex`'s
/// `@unchecked Sendable` is sound *only* because no two reindexes/writes overlap.
/// **All** index touches — every `refresh()` and every `cacheThumbnail()` — pass
/// through one serial chain (`runSerial`), draining the predecessor before they
/// start, so concurrent callers never open a second Core Spotlight batch and the
/// indexer's fingerprint-map diff can't race a concurrent `replace`. (Issue #19's
/// refresh↔refresh *coalescing* was traded for this single mechanism: two
/// overlapping refreshes now run sequentially, the second a cheap `304`.)
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
        /// reindexed. `rowCount` is the new catalog size; `upserted` the rows the
        /// indexer add/changed and `removed` the vanished ids it dropped — the
        /// delta the indexer derived against its own fingerprint map (issue #36),
        /// not the whole catalog.
        case refreshed(rowCount: Int, upserted: Int, removed: Int)
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
    /// Resolves an album's on-device cover for the lazy thumbnail attach (issue
    /// #44). `nil` when the app couldn't open a cache directory — `cacheThumbnail`
    /// then no-ops, mirroring the inert-catalog degrade path.
    private let thumbnailProvider: (any ThumbnailProviding)?
    /// Tail of the serial index-touching queue — a `refresh()` or a
    /// `cacheThumbnail()` (issue #44). Every index touch awaits its predecessor
    /// before starting, so no two Core Spotlight batches/index writes ever overlap
    /// (the soundness condition for `RealSearchableIndex`'s `@unchecked Sendable`).
    /// Ordering only; it is `Void`/`Never` so refresh and the (differently-typed)
    /// thumbnail upsert can chain through one slot. Released (`nil`) when the queue
    /// drains, via `endSerialOp`.
    private var inFlight: Task<Void, Never>?
    /// In-flight serial ops. Drives `poll()`'s short-circuit and lets the tail be
    /// released when idle. **Not** a second serialization primitive — a derived
    /// counter mutated in lockstep with chain membership; the chain (`inFlight`) is
    /// the sole ordering mechanism.
    private var activeCount = 0

    public init(
        client: APIClient,
        store: any CatalogStore,
        makeIndexer: @escaping @Sendable () -> any CatalogIndexing,
        thumbnailProvider: (any ThumbnailProviding)? = nil
    ) {
        self.client = client
        self.store = store
        self.makeIndexer = makeIndexer
        self.thumbnailProvider = thumbnailProvider
    }

    /// Append `work` to the serial index-touching chain: await any predecessor index
    /// touch, then run `work`; successors await this op in turn. Returns `work`'s
    /// result. This is the single mechanism that guarantees no two Spotlight batches
    /// / index writes overlap, in **both** directions (refresh↔upsert, upsert↔upsert,
    /// refresh↔refresh).
    ///
    /// `Task { }` created inside this actor method inherits the actor's isolation
    /// (`@_inheritActorContext` on `Task.init`'s operation), so the closure body —
    /// and its `defer` — run **on the actor**: `endSerialOp()` is a synchronous,
    /// in-actor call (a `defer` can't `await`). The only suspension points are
    /// `await predecessor?.value` and `await work()`, which hop off and back onto
    /// the actor. Cleanup runs in the **work task's** frame, not the caller's, so a
    /// cancelled caller can't free the slot while the batch is still open.
    ///
    /// Coalescing of overlapping `refresh()` calls (the issue-#19 behavior) was
    /// **dropped** for one serial mechanism (issue #44): two overlapping refreshes
    /// now run sequentially; the second re-polls and gets a cheap `304`.
    private func runSerial<T: Sendable>(_ work: @escaping @Sendable () async throws -> T) async throws -> T {
        let predecessor = inFlight
        activeCount += 1
        let task = Task<T, Error> {
            await predecessor?.value          // serialize after any predecessor index touch
            defer { self.endSerialOp() }      // synchronous, actor-isolated
            return try await work()
        }
        // Type-erased to chain heterogeneous ops (refresh returns Outcome, upsert
        // returns Void) through one `Task<Void, Never>` tail; successors only need
        // "predecessor finished", not its value.
        inFlight = Task { _ = try? await task.value }
        return try await task.value
    }

    /// Runs on the actor when a serial op's work finishes (success or throw). Frees
    /// the tail once the queue drains so `poll()` sees idle and the slot isn't retained.
    private func endSerialOp() {
        activeCount -= 1
        if activeCount == 0 { inFlight = nil }
    }

    /// Run one refresh cycle: poll conditionally, and on a `200` wholesale-replace
    /// the store and diff-reindex Spotlight. Single-flighted — a second call while
    /// one is in flight coalesces onto the first and returns its result, so the
    /// foreground and a background task can both call it without ever overlapping a
    /// Spotlight batch. (A back-to-back call after one completes simply re-polls and
    /// gets a cheap `304`, since the index watermark has advanced.)
    @discardableResult
    public func refresh() async throws -> Outcome {
        try await runSerial { try await self.performRefresh() }
    }

    /// Lazily cache and attach `albumID`'s Spotlight cover thumbnail (issue #44).
    /// Best-effort and **non-throwing**: a missing clone row, an unfetchable cover,
    /// or an index write error is logged and swallowed (the result is just the
    /// default icon — never a surfaced error). Resolves the cloned row and its
    /// thumbnail off the actor via the `Sendable` provider, then does a single,
    /// **plain non-batch** upsert that never advances the watermark. Serialized
    /// through the same chain as `refresh()` in both directions, so the upsert's
    /// index write never overlaps a reindex batch.
    ///
    /// Foreground / user-initiated only (in-app album view or search) — never the
    /// background poll leg, which must stay a cheap conditional probe.
    public func cacheThumbnail(forAlbumID albumID: Int) async {
        // runSerial only throws if `work` does; `performCacheThumbnail` is
        // non-throwing, so `try?` here can never actually swallow an error — it just
        // satisfies the generic throwing signature.
        try? await runSerial { await self.performCacheThumbnail(forAlbumID: albumID) }
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
        // touch the named index while that refresh's batch is open). Any in-flight
        // serial index touch (refresh or a thumbnail upsert) counts.
        if activeCount > 0 { return false }
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
        // (Slot cleanup is handled by runSerial/endSerialOp, in the work task's
        // frame — so a cancelled caller can't free it mid-batch.)

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
            // Replace the store first so a deep-link `row(id:)` lookup sees the new
            // rows immediately...
            try await store.replace(rows: rows, lastModified: lastModified)
            // ...then reindex from the in-memory snapshot. The indexer derives
            // add/change/remove against its OWN persisted fingerprint map (issue
            // #36), so the removed set survives this replace and is reproducible
            // across a mid-reindex crash, and unchanged rows are skipped. The
            // watermark advances only when the final endBatch succeeds; a throw
            // here leaves indexedWatermark() unchanged, so the next poll re-fetches
            // the same 200 and re-derives the identical work set.
            let summary = try await indexer.reindex(snapshot: rows, watermark: lastModified)
            return .refreshed(rowCount: rows.count, upserted: summary.upserted, removed: summary.removed)
        }
    }

    /// The serialized body of ``cacheThumbnail(forAlbumID:)``. Resolves the cloned
    /// row, then its cover bytes (off the actor, via the `Sendable` provider), then
    /// upserts the single item with the embedded `thumbnailData`. Every failure mode
    /// — no provider, absent row, miss, unreadable file, index error — short-circuits
    /// to a logged no-op, since thumbnail art is best-effort decoration.
    private func performCacheThumbnail(forAlbumID albumID: Int) async {
        guard let thumbnailProvider else { return }
        // The clone is the source of truth for the URL the reindex can re-attach;
        // a missing row means nothing to decorate. `try?` flattens the throwing,
        // optional-returning lookup to a single optional (SE-0230).
        guard let row = try? await store.row(id: albumID) else { return }
        guard let fileURL = await thumbnailProvider.localThumbnailURL(for: row),
              let data = try? Data(contentsOf: fileURL) else { return }
        do {
            try await makeIndexer().upsert(row: row, thumbnailData: data)
        } catch {
            refreshLog.debug("Thumbnail upsert failed for album \(albumID, privacy: .public): \(error.localizedDescription, privacy: .public)")
        }
    }
}
