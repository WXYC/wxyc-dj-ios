//
//  SpyCatalogIndexer.swift
//  WXYCAPITests
//
//  A recording CatalogIndexing double for the CatalogRefreshService tests (issue
//  #19 step 4). Models the real indexer's watermark semantics — indexedWatermark()
//  advances to the committed value only when reindex succeeds — with a toggle to
//  fail the reindex, so the crash-safety invariant (watermark does not advance on
//  a failed commit, and the next poll re-attempts) is testable. Lock-guarded
//  Sendable class, matching FakeSearchableIndex.
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
        let removedIDs: [Int]
        let watermark: String?
        /// The ids the indexer actually observed in the store at reindex time.
        /// The real `SpotlightCatalogIndexer` pages the store, so this models that
        /// the store must already hold the NEW rows — a test asserting this catches
        /// a service that reindexed BEFORE replacing the store.
        let observedStoreIDs: [Int]
    }

    /// Thrown when the indexer is set to fail its commit.
    struct ReindexFailure: Error {}

    private struct State {
        var watermark: String?
        var reindexCalls: [ReindexCall] = []
    }

    /// Whether `reindex` throws instead of committing. Fixed per instance (a
    /// failed Core Spotlight batch is unrecoverable in-process — recovery is a
    /// fresh indexer next launch), so it's an immutable `let`, not lock state.
    private let shouldFail: Bool
    private let state: OSAllocatedUnfairLock<State>

    init(watermark: String? = nil, shouldFail: Bool = false) {
        self.shouldFail = shouldFail
        state = OSAllocatedUnfairLock(initialState: State(watermark: watermark))
    }

    var reindexCalls: [ReindexCall] { state.withLock { $0.reindexCalls } }

    // MARK: CatalogIndexing

    func indexedWatermark() -> String? { state.withLock { $0.watermark } }

    func reindex(store: any CatalogStore, removedIDs: [Int], watermark: String?) async throws {
        // Read the store the way the real indexer does, so the recorded call
        // reflects what the index would have seen (proving replace ran first).
        let observed = (try? await store.ids()).map { $0.sorted() } ?? []
        // Record the attempt (even a failing one is observable), then decide.
        state.withLock {
            $0.reindexCalls.append(ReindexCall(
                removedIDs: removedIDs.sorted(), watermark: watermark, observedStoreIDs: observed
            ))
        }
        if shouldFail { throw ReindexFailure() }
        // Mirror the real indexer: the watermark (the index's client state)
        // advances only when the commit succeeds.
        state.withLock { $0.watermark = watermark }
    }
}
