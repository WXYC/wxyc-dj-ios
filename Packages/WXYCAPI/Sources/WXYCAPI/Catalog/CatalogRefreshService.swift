//
//  CatalogRefreshService.swift
//  WXYCAPI
//
//  The shared poll -> 304/200 -> store-replace -> Spotlight-reindex flow (issue
//  #19 step 4) the foreground path and both background tasks call. An actor that
//  serializes all index touches (refreshes + issue-#44 lazy thumbnail upserts)
//  through one chain, so the bulk runs off the main actor, the BGTask layer stays
//  thin, and there is never more than one Spotlight batch open at a time. The
//  load-bearing invariant: the poll watermark is sourced from the index commit, so
//  it advances only after Spotlight endBatch succeeds.
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

    /// What one ``poll()`` learned. Three cases, not a `Bool`, because the
    /// short-circuit and a genuine `304` mean different things to a caller that
    /// *records* the answer as well as acting on it (issue #118 review): only
    /// ``changed`` should schedule the reindex `BGProcessingTask`, but only
    /// ``unchanged`` is evidence that the catalog is actually current.
    public enum PollOutcome: Equatable, Sendable {
        /// The server answered `200` — the catalog moved, so the charging-gated
        /// reindex leg has real work to do.
        case changed
        /// The server answered `304` — the clone and index are already current.
        case unchanged
        /// No request was made: a ``refresh()`` was already in flight, and it
        /// replaces the store and reindexes anyway, so this poll had nothing to
        /// add. **Not** evidence either way about whether the catalog moved.
        case skippedRefreshInFlight
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
    /// In-flight serial ops (refresh or thumbnail upsert). Lets the tail be released
    /// when the queue drains. **Not** a second serialization primitive — a derived
    /// counter mutated in lockstep with chain membership; the chain (`inFlight`) is
    /// the sole ordering mechanism.
    private var activeCount = 0
    /// In-flight *refreshes* specifically (the ops that reindex + open a batch).
    /// `poll()` defers to this, **not** `activeCount`: a lazy thumbnail upsert
    /// neither covers the catalog work a poll would trigger nor opens a batch, so it
    /// must not suppress the poll (issue #44 — that false-negative would skip a real
    /// reindex schedule).
    private var refreshInFlight = 0
    /// Cover cache keys (`<id>-<urlhash>.jpg`) already attached to Spotlight this
    /// session, so a re-view of an unchanged cover skips a redundant upsert. Cleared
    /// whenever a reindex upserts rows (which re-write changed rows *without* a
    /// thumbnail), so the "self-heal on next view" path still re-attaches a stripped
    /// cover — keying on id alone would wedge it blank until relaunch (issue #44).
    private var attachedThumbnailKeys: Set<String> = []

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
    /// (`@_inheritActorContext` on `Task.init`'s operation), so the wrapper's
    /// continuation runs **on the actor**: `endSerialOp()` is a synchronous,
    /// in-actor call. The only suspension points are `await predecessor?.value` and
    /// `await work()`, which hop off and back onto the actor.
    ///
    /// **Counter balance is cancellation-robust.** The `activeCount += 1` is paired
    /// with the wrapper task's `endSerialOp()`, which runs when `task` *settles*
    /// (success, throw, **or** cancellation — `try?` swallows). Putting the decrement
    /// in the wrapper rather than a `defer` inside `task` means it can't be skipped
    /// by a cancellation delivered while `task` is suspended at `await
    /// predecessor?.value` (before a `defer` would even register) — so the counter
    /// can never wedge `> 0` and strand `poll()`/the tail.
    ///
    /// Coalescing of overlapping `refresh()` calls (the issue-#19 behavior) was
    /// **dropped** for one serial mechanism (issue #44): two overlapping refreshes
    /// now run sequentially; the second re-polls and gets a cheap `304`.
    private func runSerial<T: Sendable>(isRefresh: Bool, _ work: @escaping @Sendable () async throws -> T) async throws -> T {
        let predecessor = inFlight
        activeCount += 1
        if isRefresh { refreshInFlight += 1 }
        let task = Task<T, Error> {
            await predecessor?.value          // serialize after any predecessor index touch
            return try await work()
        }
        // Type-erased tail so heterogeneous ops (refresh → Outcome, upsert → Void)
        // chain through one `Task<Void, Never>`; successors only need "predecessor
        // settled". The wrapper also owns cleanup, so it always runs once `task`
        // settles regardless of how the caller's await unwinds.
        inFlight = Task {
            _ = try? await task.value
            self.endSerialOp(isRefresh: isRefresh)
        }
        return try await task.value
    }

    /// Runs on the actor when a serial op settles. Frees the tail once the queue
    /// drains so `poll()` sees idle and the slot isn't retained.
    private func endSerialOp(isRefresh: Bool) {
        activeCount -= 1
        if isRefresh { refreshInFlight -= 1 }
        if activeCount == 0 { inFlight = nil }
    }

    /// Run one refresh cycle: poll conditionally, and on a `200` wholesale-replace
    /// the store and diff-reindex Spotlight. Serialized through the shared chain, so
    /// the foreground and a background task can both call it without ever overlapping
    /// a Spotlight batch. Two overlapping refreshes run **sequentially** (issue #44
    /// dropped the old coalescing); the second re-polls and, since the first advanced
    /// the index watermark, gets a cheap `304`.
    @discardableResult
    public func refresh() async throws -> Outcome {
        try await runSerial(isRefresh: true) { try await self.performRefresh() }
    }

    /// Lazily cache and attach `albumID`'s Spotlight cover thumbnail (issue #44).
    /// Best-effort and **non-throwing**: a missing clone row, an unfetchable cover,
    /// or an index write error is logged and swallowed (the result is just the
    /// default icon — never a surfaced error). Resolves the cloned row and its
    /// thumbnail off the actor via the `Sendable` provider, then does a single,
    /// **plain non-batch** upsert that never advances the watermark.
    ///
    /// **Only the index write is serialized** through the chain — the row lookup,
    /// network fetch, downscale, and byte read all run *before* `runSerial`, so a
    /// slow CDN fetch never blocks (or is blocked by) a catalog refresh and many
    /// covers can load concurrently while only their tiny upserts queue (issue #44).
    /// Foreground / user-initiated only (in-app album view or search) — never the
    /// background poll leg, which must stay a cheap conditional probe.
    public func cacheThumbnail(forAlbumID albumID: Int) async {
        guard let thumbnailProvider else { return }
        // The clone is the source of truth for the URL the reindex can re-attach;
        // a missing row means nothing to decorate. `try?` flattens the throwing,
        // optional-returning lookup to a single optional (SE-0230).
        guard let row = try? await store.row(id: albumID) else { return }
        // Resolve the cover OFF the serial chain (the provider fetches/downscales on
        // its own actor); only the index write below is serialized. The cache key
        // (`<id>-<urlhash>`) is the cover's identity — a *changed* cover yields a new
        // key, so it is not deduped against the old one.
        guard let fileURL = await thumbnailProvider.localThumbnailURL(for: row) else { return }
        let cacheKey = fileURL.lastPathComponent
        // Fast-path: already attached this session. Best-effort only (a stale read
        // races a reindex's clear / a concurrent attach) — the authoritative re-check
        // is inside the serialized `attachThumbnail` below, so a miss here at worst
        // pays one redundant, idempotent upsert.
        guard !attachedThumbnailKeys.contains(cacheKey) else { return }
        guard let data = try? Data(contentsOf: fileURL) else { return }
        do {
            try await runSerial(isRefresh: false) {
                try await self.attachThumbnail(cacheKey: cacheKey, row: row, data: data)
            }
        } catch {
            refreshLog.debug("Thumbnail upsert failed for album \(albumID, privacy: .public): \(error.localizedDescription, privacy: .public)")
        }
    }

    /// The serialized check-upsert-record unit for ``cacheThumbnail(forAlbumID:)``.
    /// Runs as one `runSerial` op, so the dedup re-check, the upsert, and the insert
    /// are never interleaved with another attach or a reindex: two concurrent views
    /// of the same cover collapse to a single upsert (the second re-check sees the
    /// key), and a reindex's `attachedThumbnailKeys.removeAll()` can't land between
    /// this re-check and its insert (it is a separate serial op, ordered before or
    /// after this whole unit, never inside it). Keeping the insert outside the serial
    /// region — as a naive `contains`-then-`insert` straddling the await would —
    /// reopens both races (a double upsert, and a stripped cover wedged blank until
    /// relaunch when an insert lands after the clear).
    private func attachThumbnail(cacheKey: String, row: CatalogRow, data: Data) async throws {
        guard !attachedThumbnailKeys.contains(cacheKey) else { return }
        try await makeIndexer().upsert(row: row, thumbnailData: data)
        attachedThumbnailKeys.insert(cacheKey)
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
    /// the refresh holds an open batch. It defers only to a *refresh*
    /// (`refreshInFlight`), **not** to a lazy thumbnail upsert: an upsert doesn't
    /// reindex (so it wouldn't cover the work this poll would trigger) and opens no
    /// batch (so the client-state read is safe) — deferring to it would wrongly
    /// skip scheduling a reindex for a genuinely changed catalog (issue #44). A
    /// refresh that *starts during* a poll is rare (the poll runs only in the
    /// background app-refresh task, the refresh in the foreground or the
    /// charging-gated reindex leg) and benign — the worst case is a stale watermark
    /// read that yields a redundant conditional GET, never data corruption.
    ///
    /// **Known cost (tracked as a follow-up).** On a `200` this still pays the
    /// full body download + ~50k-row decode just to return `true`; a body-less
    /// `HEAD`/lightweight probe would avoid it but needs a Backend-Service change.
    ///
    /// Returns a ``PollOutcome`` rather than a `Bool` (issue #118 review) so the
    /// short-circuit above is distinguishable from a genuine `304`. Both used to
    /// collapse to `false`, which was harmless while the only consumer asked
    /// "should I schedule a reindex?" — but the caller now also *records* the
    /// answer, and reporting a skipped poll as "the catalog didn't move" is
    /// exactly the null-answer bias issue #118 item 3 exists to remove.
    public func poll() async throws -> PollOutcome {
        // Defer only to an in-flight refresh (which replaces the store + reindexes
        // and opens a batch). A thumbnail upsert in flight must NOT suppress the
        // poll — it doesn't reindex, so a real catalog change would be missed.
        if refreshInFlight > 0 { return .skippedRefreshInFlight }
        switch try await conditionalFetch(using: makeIndexer()) {
        case .notModified:
            return .unchanged
        case .modified:
            return .changed
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
            // A reindex re-upserts changed rows via the no-thumbnail mapping (the
            // cached-only attach is the deferred PR-2 half), stripping their covers —
            // so the attached-keys dedup must be dropped, or a stripped cover's key
            // lingers and the "self-heal on next view" path skips the re-attach.
            // Clear on a **throw too**: a multi-batch reindex commits batch by batch,
            // so a failure after some batches has already stripped those covers; only
            // clearing on success would wedge them blank until the next *successful*
            // refresh. (Over-clearing is harmless — a redundant idempotent re-attach.)
            let summary: ReindexSummary
            do {
                summary = try await indexer.reindex(snapshot: rows, watermark: lastModified)
            } catch {
                attachedThumbnailKeys.removeAll()
                throw error
            }
            if summary.upserted > 0 { attachedThumbnailKeys.removeAll() }
            return .refreshed(rowCount: rows.count, upserted: summary.upserted, removed: summary.removed)
        }
    }
}
