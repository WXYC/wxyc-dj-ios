//
//  FakeSearchableIndex.swift
//  WXYCAPITests
//
//  Recording SearchableIndexing double for the Spotlight indexer tests (issue
//  #19 step 3). Records the Sendable projection of every indexed item, the
//  chunk sizes, the deleted identifiers, and the committed client state, with a
//  hook to throw on a chosen operation (for the crash-safety path). A
//  lock-guarded Sendable class, NOT an actor — an actor would push the
//  non-Sendable [CSSearchableItem] across an isolation boundary.
//
//  Created by Jake on 06/23/26.
//  Copyright © 2026 WXYC. All rights reserved.
//

import CoreSpotlight
import Foundation
import os
@testable import WXYCAPI

final class FakeSearchableIndex: SearchableIndexing {
    /// The Sendable fields the tests assert on, lifted off each non-Sendable
    /// `CSSearchableItem` as it arrives (so the item never crosses a boundary).
    struct IndexedItem: Sendable, Equatable {
        let identifier: String?
        let domainIdentifier: String?
        let title: String?
        let contentDescription: String?
        let artist: String?
        let album: String?
        let keywords: [String]?
        /// The embedded Spotlight thumbnail bytes (issue #44), so a test can assert
        /// a lazy/reindex upsert carried the cover (or, for a plain reindex, didn't).
        let thumbnailData: Data?
    }

    /// The operation the fake should throw on, to exercise the indexer's
    /// commit-only-on-success behavior.
    enum FailurePoint: Sendable { case indexItems, deleteItems, endBatch }

    struct Recording: Sendable {
        var beginCount = 0
        var endCount = 0
        /// Sizes of each `indexItems` call, in order — pins the chunking.
        var indexBatchSizes: [Int] = []
        var indexedItems: [IndexedItem] = []
        var deletedIdentifiers: [String] = []
        /// The 1-based batch number (`beginCount` at delete time) each `deleteItems`
        /// call landed in — lets a test prove deletes ride the final
        /// (watermark-bearing) batch, not an intermediate empty-state one.
        var deletedInBatch: [Int] = []
        /// The client state from the most recent `endBatch` (what `lastClientState`
        /// returns).
        var committedClientState: Data?
        /// Every `endBatch` client state in order — pins which batch advanced the
        /// watermark, so a test can assert intermediate batches commit empty state
        /// and only the final batch carries the real watermark.
        var committedClientStates: [Data] = []
    }

    struct FakeError: Error {}

    private let state: OSAllocatedUnfairLock<Recording>
    private let failOn: FailurePoint?
    /// Throw on the Nth `indexItems` call (1-based), so a test can fail a *later*
    /// batch after earlier ones have already committed — the multi-batch
    /// crash-safety path `failOn: .indexItems` (which fails the first call) can't
    /// reach.
    private let failIndexItemsOnCall: Int?

    init(initialClientState: Data? = nil, failOn: FailurePoint? = nil, failIndexItemsOnCall: Int? = nil) {
        self.state = OSAllocatedUnfairLock(
            initialState: Recording(committedClientState: initialClientState)
        )
        self.failOn = failOn
        self.failIndexItemsOnCall = failIndexItemsOnCall
    }

    var recording: Recording { state.withLock { $0 } }

    /// The most recent committed client state decoded as a ``CatalogIndexState``
    /// (issue #36's watermark + fingerprint map), or `nil` if nothing was
    /// committed. Lets a test read the persisted map and watermark directly.
    var committedIndexState: CatalogIndexState? {
        guard let data = recording.committedClientState, !data.isEmpty else { return nil }
        return CatalogIndexState(decoding: data)
    }

    /// Every committed client state decoded, in order — to assert intermediate
    /// batches preserved the old map / withheld the watermark while only the
    /// final batch advanced both. A blob that doesn't decode surfaces as
    /// ``CatalogIndexState/empty`` rather than vanishing.
    var committedIndexStates: [CatalogIndexState] {
        recording.committedClientStates.map { CatalogIndexState(decoding: $0) ?? .empty }
    }

    // MARK: SearchableIndexing

    func beginBatch() {
        state.withLock { $0.beginCount += 1 }
    }

    func indexItems(_ items: [CSSearchableItem]) async throws {
        if failOn == .indexItems { throw FakeError() }
        // 1-based ordinal of this call = already-recorded calls + 1.
        if let failIndexItemsOnCall, state.withLock({ $0.indexBatchSizes.count + 1 }) == failIndexItemsOnCall {
            throw FakeError()
        }
        let projected = items.map { item in
            IndexedItem(
                identifier: item.uniqueIdentifier,
                domainIdentifier: item.domainIdentifier,
                title: item.attributeSet.title,
                contentDescription: item.attributeSet.contentDescription,
                artist: item.attributeSet.artist,
                album: item.attributeSet.album,
                keywords: item.attributeSet.keywords,
                thumbnailData: item.attributeSet.thumbnailData
            )
        }
        state.withLock {
            $0.indexBatchSizes.append(projected.count)
            $0.indexedItems.append(contentsOf: projected)
        }
    }

    func deleteItems(withIdentifiers identifiers: [String]) async throws {
        if failOn == .deleteItems { throw FakeError() }
        state.withLock {
            $0.deletedIdentifiers.append(contentsOf: identifiers)
            $0.deletedInBatch.append($0.beginCount)
        }
    }

    func endBatch(clientState: Data) async throws {
        if failOn == .endBatch { throw FakeError() }
        state.withLock {
            $0.endCount += 1
            $0.committedClientState = clientState
            $0.committedClientStates.append(clientState)
        }
    }

    func lastClientState() async throws -> Data? {
        state.withLock { $0.committedClientState }
    }
}
