//
//  SpyCatalogIndexer.swift
//  WXYCAPITests
//
//  A recording CatalogIndexing double for the CatalogRefreshService tests. Models
//  the real indexer's persisted state — an id->fingerprint map plus the watermark
//  (issue #36) — so it derives the same add/change/remove diff the service relies
//  on for its Outcome, and advances both only when reindex succeeds. A toggle
//  fails the reindex so the crash-safety invariant (neither watermark nor map
//  advances on a failed commit, and the next poll re-attempts) stays testable.
//  Lock-guarded Sendable class, matching FakeSearchableIndex.
//
//  Created by Jake on 06/23/26.
//  Copyright © 2026 WXYC. All rights reserved.
//

import Foundation
import os
@testable import WXYCAPI

final class SpyCatalogIndexer: CatalogIndexing {
    /// One recorded `reindex`, lifted to a Sendable, assertable shape.
    struct ReindexCall: Sendable, Equatable {
        /// The ids of the snapshot the service handed the indexer, sorted. The
        /// service replaces the store *before* reindexing, so these must be the
        /// NEW export ids — a service that reindexed before replacing would be
        /// caught by the companion `SpyCatalogStore.replaceCalls` assertion.
        let snapshotIDs: [Int]
        let watermark: String?
        /// The delta this spy derived from the snapshot vs. its persisted map —
        /// the same numbers the real indexer reports in its ``ReindexSummary``.
        let upserted: Int
        let removed: Int
    }

    /// One recorded `upsert(row:thumbnailData:)` — the lazy thumbnail attach (#44).
    struct UpsertCall: Sendable, Equatable {
        let rowID: Int
        let thumbnailData: Data?
    }

    /// Thrown when the indexer is set to fail its commit.
    struct ReindexFailure: Error {}

    private struct State {
        var watermark: String?
        /// The index's persisted record of what it holds — `album id ->
        /// fingerprint`. Seeded from the rows the index already held, advanced to
        /// the new snapshot only on a successful reindex.
        var fingerprints: [Int: UInt64]
        var reindexCalls: [ReindexCall] = []
        var upsertCalls: [UpsertCall] = []
    }

    /// Whether `reindex` throws instead of committing. Fixed per instance (a
    /// failed Core Spotlight batch is unrecoverable in-process — recovery is a
    /// fresh indexer next launch), so it's an immutable `let`, not lock state.
    private let shouldFail: Bool
    private let state: OSAllocatedUnfairLock<State>

    /// Seed the index's persisted state: `watermark` and the fingerprint map
    /// derived from `indexedRows` (the rows the index already holds). The diff a
    /// later `reindex` computes is `snapshot` vs. these fingerprints.
    init(watermark: String? = nil, indexedRows: [CatalogRow] = [], shouldFail: Bool = false) {
        self.shouldFail = shouldFail
        var fingerprints: [Int: UInt64] = [:]
        for row in indexedRows { fingerprints[row.id] = CatalogSpotlight.fingerprint(for: row) }
        state = OSAllocatedUnfairLock(initialState: State(watermark: watermark, fingerprints: fingerprints))
    }

    var reindexCalls: [ReindexCall] { state.withLock { $0.reindexCalls } }
    var upsertCalls: [UpsertCall] { state.withLock { $0.upsertCalls } }

    // MARK: CatalogIndexing

    func indexedWatermark() -> String? { state.withLock { $0.watermark } }

    /// Record the lazy thumbnail upsert. Models the real non-batch write: it
    /// records the attach but leaves the watermark and fingerprint map untouched.
    func upsert(row: CatalogRow, thumbnailData: Data?) async throws {
        state.withLock {
            $0.upsertCalls.append(UpsertCall(rowID: row.id, thumbnailData: thumbnailData))
        }
    }

    @discardableResult
    func reindex(snapshot: [CatalogRow], watermark: String?) async throws -> ReindexSummary {
        // Diff the snapshot against the persisted map exactly as the real indexer
        // does, so the recorded delta and the returned summary match production.
        let oldMap = state.withLock { $0.fingerprints }
        var map: [Int: UInt64] = [:]
        var upsertedCount = 0
        for row in snapshot {
            let fingerprint = CatalogSpotlight.fingerprint(for: row)
            map[row.id] = fingerprint
            if oldMap[row.id] != fingerprint { upsertedCount += 1 }
        }
        let newMap = map
        let upserted = upsertedCount
        let removed = oldMap.keys.filter { newMap[$0] == nil }.count

        // Record the attempt (even a failing one is observable), then decide.
        state.withLock {
            $0.reindexCalls.append(ReindexCall(
                snapshotIDs: snapshot.map(\.id).sorted(),
                watermark: watermark, upserted: upserted, removed: removed
            ))
        }
        if shouldFail { throw ReindexFailure() }
        // Mirror the real indexer: the watermark AND the map (the index's client
        // state) advance together, only on a successful commit.
        state.withLock {
            $0.watermark = watermark
            $0.fingerprints = newMap
        }
        return ReindexSummary(upserted: upserted, removed: removed)
    }
}
