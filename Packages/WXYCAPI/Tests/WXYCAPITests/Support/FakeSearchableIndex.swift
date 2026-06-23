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
        var committedClientState: Data?
    }

    struct FakeError: Error {}

    private let state: OSAllocatedUnfairLock<Recording>
    private let failOn: FailurePoint?

    init(initialClientState: Data? = nil, failOn: FailurePoint? = nil) {
        self.state = OSAllocatedUnfairLock(
            initialState: Recording(committedClientState: initialClientState)
        )
        self.failOn = failOn
    }

    var recording: Recording { state.withLock { $0 } }

    // MARK: SearchableIndexing

    func beginBatch() {
        state.withLock { $0.beginCount += 1 }
    }

    func indexItems(_ items: [CSSearchableItem]) async throws {
        if failOn == .indexItems { throw FakeError() }
        let projected = items.map { item in
            IndexedItem(
                identifier: item.uniqueIdentifier,
                domainIdentifier: item.domainIdentifier,
                title: item.attributeSet.title,
                contentDescription: item.attributeSet.contentDescription,
                artist: item.attributeSet.artist,
                album: item.attributeSet.album,
                keywords: item.attributeSet.keywords
            )
        }
        state.withLock {
            $0.indexBatchSizes.append(projected.count)
            $0.indexedItems.append(contentsOf: projected)
        }
    }

    func deleteItems(withIdentifiers identifiers: [String]) async throws {
        if failOn == .deleteItems { throw FakeError() }
        state.withLock { $0.deletedIdentifiers.append(contentsOf: identifiers) }
    }

    func endBatch(clientState: Data) async throws {
        if failOn == .endBatch { throw FakeError() }
        state.withLock {
            $0.endCount += 1
            $0.committedClientState = clientState
        }
    }

    func lastClientState() async throws -> Data? {
        state.withLock { $0.committedClientState }
    }
}
