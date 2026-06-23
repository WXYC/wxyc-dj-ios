//
//  SpotlightCatalogIndexerTests.swift
//  WXYCAPITests
//
//  Tests the Core Spotlight indexer (issue #19 step 3) against FakeSearchableIndex
//  and a real SQLiteCatalogStore: diff-upsert of every row, chunked batches,
//  targeted deletes, the watermark committed once at endBatch, and the
//  commit-only-on-success crash-safety property step 4's invariant relies on.
//
//  Created by Jake on 06/23/26.
//  Copyright © 2026 WXYC. All rights reserved.
//

import Foundation
import Testing
@testable import WXYCAPI

@Suite("SpotlightCatalogIndexer")
struct SpotlightCatalogIndexerTests {
    // MARK: Store helpers (a real SQLiteCatalogStore exercises rows(after:limit:) too)

    static func withStore(
        rows: [CatalogRow],
        watermark: String? = nil,
        _ body: (SQLiteCatalogStore) async throws -> Void
    ) async throws {
        let url = CatalogStoreTestSupport.tempStoreURL()
        defer { CatalogStoreTestSupport.removeStoreFile(url) }
        do {
            let store = try SQLiteCatalogStore(url: url)
            try await store.replace(rows: rows, lastModified: watermark)
            try await body(store)
        }
    }

    // MARK: Tests

    @Test func upsertsEveryRowAsSearchableItemAndCommitsWatermark() async throws {
        try await Self.withStore(rows: CatalogStoreTestSupport.numberedRows(3)) { store in
            let fake = FakeSearchableIndex()
            let indexer = SpotlightCatalogIndexer(index: fake)

            try await indexer.reindex(store: store, removedIDs: [], watermark: "Mon, 01 Jun 2026 12:00:00 GMT")

            let rec = fake.recording
            #expect(rec.beginCount == 1)
            #expect(rec.endCount == 1)
            #expect(rec.indexedItems.map(\.identifier) == ["album.1", "album.2", "album.3"])
            #expect(rec.indexedItems.allSatisfy { $0.domainIdentifier == "catalog" })
            #expect(rec.indexedItems.map(\.title) == ["Album 1", "Album 2", "Album 3"])
            #expect(rec.deletedIdentifiers.isEmpty)
            #expect(rec.committedClientState == Data("Mon, 01 Jun 2026 12:00:00 GMT".utf8))
            #expect(try await indexer.indexedWatermark() == "Mon, 01 Jun 2026 12:00:00 GMT")
        }
    }

    @Test func chunksIndexCallsAtChunkSize() async throws {
        try await Self.withStore(rows: CatalogStoreTestSupport.numberedRows(5)) { store in
            let fake = FakeSearchableIndex()
            let indexer = SpotlightCatalogIndexer(index: fake, chunkSize: 2)

            try await indexer.reindex(store: store, removedIDs: [], watermark: nil)

            // 5 rows at chunkSize 2 → batches of 2, 2, 1.
            #expect(fake.recording.indexBatchSizes == [2, 2, 1])
            #expect(fake.recording.indexedItems.count == 5)
        }
    }

    @Test func deletesOnlyRemovedIDsByIdentifier() async throws {
        try await Self.withStore(rows: CatalogStoreTestSupport.numberedRows(3)) { store in
            let fake = FakeSearchableIndex()
            let indexer = SpotlightCatalogIndexer(index: fake)

            try await indexer.reindex(store: store, removedIDs: [42, 7], watermark: nil)

            #expect(fake.recording.deletedIdentifiers == ["album.42", "album.7"])
        }
    }

    @Test func nilWatermarkCommitsEmptyStateAndReadsBackNil() async throws {
        try await Self.withStore(rows: CatalogStoreTestSupport.numberedRows(1)) { store in
            let fake = FakeSearchableIndex()
            let indexer = SpotlightCatalogIndexer(index: fake)

            try await indexer.reindex(store: store, removedIDs: [], watermark: nil)

            #expect(fake.recording.committedClientState == Data())
            #expect(try await indexer.indexedWatermark() == nil)
        }
    }

    @Test func emptyStoreOpensAndClosesBatchWithNoIndexCalls() async throws {
        try await Self.withStore(rows: []) { store in
            let fake = FakeSearchableIndex()
            let indexer = SpotlightCatalogIndexer(index: fake)

            try await indexer.reindex(store: store, removedIDs: [], watermark: "w")

            let rec = fake.recording
            #expect(rec.beginCount == 1)
            #expect(rec.endCount == 1)
            #expect(rec.indexBatchSizes.isEmpty)
            #expect(rec.indexedItems.isEmpty)
        }
    }

    @Test func throwMidCommitLeavesPriorWatermarkUnchanged() async throws {
        // Crash-safety seam for step 4: a failure during the commit must not
        // advance the index watermark, so the next refresh re-attempts.
        try await Self.withStore(rows: CatalogStoreTestSupport.numberedRows(2)) { store in
            let fake = FakeSearchableIndex(
                initialClientState: Data("OLD-WATERMARK".utf8),
                failOn: .endBatch
            )
            let indexer = SpotlightCatalogIndexer(index: fake)

            await #expect(throws: FakeSearchableIndex.FakeError.self) {
                try await indexer.reindex(store: store, removedIDs: [], watermark: "NEW-WATERMARK")
            }

            #expect(fake.recording.endCount == 0)
            let restored = try await indexer.indexedWatermark()
            #expect(restored == "OLD-WATERMARK")
        }
    }

    @Test func indexedWatermarkIsNilWhenIndexNeverPopulated() async throws {
        let fake = FakeSearchableIndex()
        let indexer = SpotlightCatalogIndexer(index: fake)
        #expect(try await indexer.indexedWatermark() == nil)
    }
}
