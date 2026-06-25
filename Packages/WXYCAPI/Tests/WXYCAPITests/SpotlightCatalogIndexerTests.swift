//
//  SpotlightCatalogIndexerTests.swift
//  WXYCAPITests
//
//  Tests the Core Spotlight indexer (issue #36) against FakeSearchableIndex: the
//  add/change/remove/unchanged diff against the index's own persisted fingerprint
//  map, delta-only upserts, chunked upserts AND deletes, the watermark + map
//  advanced together only on the final batch, and the crash-reproducible delete
//  — a vanished id re-derived from the surviving map by a fresh indexer.
//
//  Created by Jake on 06/23/26.
//  Copyright © 2026 WXYC. All rights reserved.
//

import Foundation
import Testing
@testable import WXYCAPI

@Suite("SpotlightCatalogIndexer")
struct SpotlightCatalogIndexerTests {
    // MARK: Row + state helpers

    /// A WXYC-representative stand-in row with the given id; override `albumTitle`
    /// or `artworkURL` to forge a fingerprinted change for a change test.
    static func row(_ id: Int, albumTitle: String? = nil, artworkURL: URL? = nil) -> CatalogRow {
        CatalogRow(
            id: id, artistName: "Artist \(id)", albumTitle: albumTitle ?? "Album \(id)",
            codeLetters: "AAA", codeNumber: id, codeArtistNumber: 1,
            label: nil, genreName: nil, formatName: nil,
            onStreaming: nil, plays: nil, artworkURL: artworkURL,
            rotationBin: nil, rotationKillDate: nil
        )
    }

    static func numberedRows(_ count: Int) -> [CatalogRow] {
        (1...count).map { row($0) }
    }

    /// The fingerprint map for `rows` — the index's persisted record of holding them.
    static func map(_ rows: [CatalogRow]) -> [Int: UInt64] {
        var map: [Int: UInt64] = [:]
        for row in rows { map[row.id] = CatalogSpotlight.fingerprint(for: row) }
        return map
    }

    /// Encode the "index currently holds `rows` at `watermark`" state as the
    /// client-state blob a prior reindex would have committed.
    static func seed(rows: [CatalogRow], watermark: String?) -> Data {
        CatalogIndexState(watermark: watermark, fingerprints: map(rows)).encode()
    }

    // MARK: First-ever index (empty map -> all adds)

    @Test func firstIndexUpsertsEveryRowAndCommitsWatermarkAndMap() async throws {
        let fake = FakeSearchableIndex()   // never populated
        let indexer = SpotlightCatalogIndexer(index: fake)
        let rows = Self.numberedRows(3)

        let summary = try await indexer.reindex(snapshot: rows, watermark: "Mon, 01 Jun 2026 12:00:00 GMT")

        let rec = fake.recording
        #expect(rec.beginCount == 1)
        #expect(rec.endCount == 1)
        #expect(rec.indexedItems.map(\.identifier) == ["album.1", "album.2", "album.3"])
        #expect(rec.indexedItems.allSatisfy { $0.domainIdentifier == "catalog" })
        #expect(rec.indexedItems.map(\.title) == ["Album 1", "Album 2", "Album 3"])
        #expect(rec.deletedIdentifiers.isEmpty)
        #expect(summary == ReindexSummary(upserted: 3, removed: 0))
        // Watermark AND the fingerprint map for all three rows are committed.
        #expect(fake.committedIndexState?.watermark == "Mon, 01 Jun 2026 12:00:00 GMT")
        #expect(fake.committedIndexState?.fingerprints == Self.map(rows))
        #expect(try await indexer.indexedWatermark() == "Mon, 01 Jun 2026 12:00:00 GMT")
    }

    @Test func indexedWatermarkIsNilWhenIndexNeverPopulated() async throws {
        let indexer = SpotlightCatalogIndexer(index: FakeSearchableIndex())
        #expect(try await indexer.indexedWatermark() == nil)
    }

    @Test func nilWatermarkCommitsStateThatReadsBackNil() async throws {
        let fake = FakeSearchableIndex()
        let indexer = SpotlightCatalogIndexer(index: fake)

        try await indexer.reindex(snapshot: Self.numberedRows(1), watermark: nil)

        #expect(fake.committedIndexState?.watermark == nil)
        #expect(try await indexer.indexedWatermark() == nil)
    }

    // MARK: Single-item non-batch upsert (issue #44 lazy thumbnail attach)

    @Test func upsertWritesOneItemWithThumbnailDataAndTouchesNoClientState() async throws {
        // The lazy thumbnail attach (#44) upserts ONE row's item with embedded
        // cover bytes as a plain, NON-batch index write — it must not open a batch
        // or commit client state, so a thumbnail attach never advances the catalog
        // watermark (which would let the next poll 304 past a not-yet-reindexed
        // catalog).
        let seed = Self.seed(rows: [Self.row(1)], watermark: "OLD")
        let fake = FakeSearchableIndex(initialClientState: seed)
        let indexer = SpotlightCatalogIndexer(index: fake)
        let bytes = Data([0xFF, 0xD8, 0xFF, 0xE0])

        try await indexer.upsert(row: Self.row(1), thumbnailData: bytes)

        let rec = fake.recording
        #expect(rec.indexedItems.map(\.identifier) == ["album.1"])
        #expect(rec.indexedItems.first?.thumbnailData == bytes)
        // The full attribute set, never a thumbnail-only partial item (which would
        // drop displayName/keywords -> -1001 / search regression, cf. #32).
        #expect(rec.indexedItems.first?.title == "Album 1")
        #expect(rec.indexedItems.first?.keywords?.isEmpty == false)
        // No batch, no client-state commit -> the watermark is untouched.
        #expect(rec.beginCount == 0)
        #expect(rec.endCount == 0)
        #expect(try await indexer.indexedWatermark() == "OLD")
    }

    @Test func upsertWithoutThumbnailStillWritesTheFullItem() async throws {
        // A nil thumbnail (unfetchable cover) still upserts the searchable item —
        // the row is never dropped; it just shows the default icon.
        let fake = FakeSearchableIndex()
        let indexer = SpotlightCatalogIndexer(index: fake)

        try await indexer.upsert(row: Self.row(7), thumbnailData: nil)

        let rec = fake.recording
        #expect(rec.indexedItems.map(\.identifier) == ["album.7"])
        #expect(rec.indexedItems.first?.thumbnailData == nil)
        #expect(rec.beginCount == 0 && rec.endCount == 0)
    }

    // MARK: Delta — unchanged rows are skipped

    @Test func unchangedSnapshotUpsertsNothingButStillAdvancesWatermark() async throws {
        // A 200 whose changes are confined to non-fingerprinted fields (or no real
        // change) must NOT re-upsert the catalog — but must still advance the
        // watermark, or the next poll re-fetches the same 200 forever.
        let rows = Self.numberedRows(3)
        let fake = FakeSearchableIndex(initialClientState: Self.seed(rows: rows, watermark: "OLD"))
        let indexer = SpotlightCatalogIndexer(index: fake)

        let summary = try await indexer.reindex(snapshot: rows, watermark: "NEW")

        let rec = fake.recording
        #expect(rec.indexBatchSizes.isEmpty)        // zero indexItems calls
        #expect(rec.deletedIdentifiers.isEmpty)
        #expect(rec.beginCount == 1 && rec.endCount == 1)   // one empty commit
        #expect(summary == ReindexSummary(upserted: 0, removed: 0))
        #expect(fake.committedIndexState?.watermark == "NEW")
        #expect(try await indexer.indexedWatermark() == "NEW")
    }

    @Test func changingOneRowReupsertsExactlyThatRow() async throws {
        // Acceptance criterion: a 200 that changes one existing row's metadata
        // re-upserts EXACTLY that row — not zero (stale), not the whole catalog.
        let original = [Self.row(1), Self.row(2)]
        let fake = FakeSearchableIndex(initialClientState: Self.seed(rows: original, watermark: "OLD"))
        let indexer = SpotlightCatalogIndexer(index: fake)

        // Row 1's album title changes; row 2 is byte-identical.
        let changed = [Self.row(1, albumTitle: "Album 1 (Remaster)"), Self.row(2)]
        let summary = try await indexer.reindex(snapshot: changed, watermark: "NEW")

        let rec = fake.recording
        #expect(rec.indexedItems.map(\.identifier) == ["album.1"])      // exactly that row
        #expect(rec.indexedItems.map(\.title) == ["Album 1 (Remaster)"]) // reflecting the new metadata
        #expect(rec.deletedIdentifiers.isEmpty)
        #expect(summary == ReindexSummary(upserted: 1, removed: 0))
        // The persisted map now records row 1's new fingerprint.
        #expect(fake.committedIndexState?.fingerprints[1] == CatalogSpotlight.fingerprint(for: changed[0]))
    }

    @Test func artworkOnlyChangeReupserts() async throws {
        // #44 sequences thumbnails on top of this; an artwork-only change must
        // re-upsert so the thumbnail refreshes on a change day.
        let original = [Self.row(1, artworkURL: URL(string: "https://img.example/old.jpg"))]
        let fake = FakeSearchableIndex(initialClientState: Self.seed(rows: original, watermark: "OLD"))
        let indexer = SpotlightCatalogIndexer(index: fake)

        let changed = [Self.row(1, artworkURL: URL(string: "https://img.example/new.jpg"))]
        let summary = try await indexer.reindex(snapshot: changed, watermark: "NEW")

        #expect(fake.recording.indexedItems.map(\.identifier) == ["album.1"])
        #expect(summary == ReindexSummary(upserted: 1, removed: 0))
    }

    // MARK: Add + change + remove together

    @Test func addChangeRemoveProducesExactlyTheDelta() async throws {
        // Acceptance criterion: an export that simultaneously adds, changes, and
        // removes yields exactly {add ∪ change} upserts and {remove} deletes.
        let original = [Self.row(1), Self.row(2), Self.row(3)]
        let fake = FakeSearchableIndex(initialClientState: Self.seed(rows: original, watermark: "OLD"))
        let indexer = SpotlightCatalogIndexer(index: fake)

        // 1 changed, 2 unchanged, 3 removed, 4 added.
        let snapshot = [Self.row(1, albumTitle: "Changed"), Self.row(2), Self.row(4)]
        let summary = try await indexer.reindex(snapshot: snapshot, watermark: "NEW")

        let rec = fake.recording
        // Upserts in snapshot order: 1 (changed), 4 (added). 2 (unchanged) skipped.
        #expect(rec.indexedItems.map(\.identifier) == ["album.1", "album.4"])
        #expect(rec.deletedIdentifiers == ["album.3"])
        #expect(summary == ReindexSummary(upserted: 2, removed: 1))
        #expect(fake.committedIndexState?.fingerprints.keys.sorted() == [1, 2, 4])
    }

    // MARK: Crash-reproducible delete (the headline fix)

    @Test func vanishedIdIsRemovedOnRetryWithAFreshIndexerAfterAMidCommitCrash() async throws {
        // Acceptance criterion 1: a vanished album is removed from Spotlight even
        // when the reindex crashes mid-commit and is retried on a later launch
        // with a fresh indexer. The persisted map must survive the crash so the
        // delete is RE-DERIVED — not recomputed to empty (the old store-derived
        // bug, where `replace` had already dropped the only record of the vanish).
        let indexed = [Self.row(1), Self.row(2), Self.row(3)]
        let seed = Self.seed(rows: indexed, watermark: "OLD")

        // Run 1: a fresh indexer over an index whose endBatch fails — a mid-commit
        // crash. Snapshot drops id 3 (1 & 2 unchanged), so the only work is the
        // delete of album.3, which never commits.
        let crashed = FakeSearchableIndex(initialClientState: seed, failOn: .endBatch)
        let indexer1 = SpotlightCatalogIndexer(index: crashed)
        await #expect(throws: FakeSearchableIndex.FakeError.self) {
            try await indexer1.reindex(snapshot: [Self.row(1), Self.row(2)], watermark: "NEW")
        }
        // The persisted client state is unchanged: still the OLD map, which STILL
        // records id 3. This is what survives the crash.
        let survived = try #require(crashed.recording.committedClientState)
        let survivedState = try #require(CatalogIndexState(decoding: survived))
        #expect(survivedState.watermark == "OLD")          // watermark not advanced
        #expect(survivedState.fingerprints.keys.contains(3))   // the vanished id survives

        // Run 2: a FRESH indexer over a FRESH handle reading the SAME persisted
        // client state (modelling the daemon's shared resume token). The delete is
        // re-derived from the surviving map and applied.
        let recovered = FakeSearchableIndex(initialClientState: survived)
        let indexer2 = SpotlightCatalogIndexer(index: recovered)
        let summary = try await indexer2.reindex(snapshot: [Self.row(1), Self.row(2)], watermark: "NEW")

        #expect(recovered.recording.deletedIdentifiers == ["album.3"])   // not lost
        #expect(summary == ReindexSummary(upserted: 0, removed: 1))
        #expect(recovered.committedIndexState?.fingerprints.keys.sorted() == [1, 2])
        #expect(recovered.committedIndexState?.watermark == "NEW")
        #expect(try await indexer2.indexedWatermark() == "NEW")
    }

    // MARK: Atomic, final-batch-only commit (watermark + map together)

    @Test func intermediateBatchesCommitCumulativeAppliedMapAndWithholdWatermark() async throws {
        // Crash-safety crux: across a multi-batch reindex each batch commits the map
        // of work applied SO FAR (so the persisted map matches what the index
        // physically holds between batches) and withholds the watermark (nil); only
        // the final batch advances it. Old map = {10,11} (both vanish); adds {1,2,3}.
        let removedRows = [Self.row(10), Self.row(11)]
        let fake = FakeSearchableIndex(initialClientState: Self.seed(rows: removedRows, watermark: "OLD"))
        let indexer = SpotlightCatalogIndexer(index: fake, chunkSize: 2)

        let snapshot = Self.numberedRows(3)   // ids 1,2,3 — all adds
        let summary = try await indexer.reindex(snapshot: snapshot, watermark: "W")

        let rec = fake.recording
        // upserts [1,2,3] then deletes [10,11], packed ≤2/batch:
        //   batch1 = upsert 1,2            -> cumulative {1,2,10,11}
        //   batch2 = upsert 3 + delete 10  -> cumulative {1,2,3,11}
        //   batch3 = delete 11 (final)     -> cumulative {1,2,3}
        #expect(rec.indexBatchSizes == [2, 1])
        #expect(rec.deletedIdentifiers == ["album.10", "album.11"])
        #expect(rec.deletedInBatch == [2, 3])          // deletes are chunked, not all on one batch
        #expect(rec.beginCount == 3 && rec.endCount == 3)
        // Each commit reflects the work applied so far; intermediates withhold the
        // watermark, the final carries it with the complete map.
        let afterBatch1 = CatalogIndexState(watermark: nil, fingerprints: Self.map([Self.row(1), Self.row(2)] + removedRows))
        let afterBatch2 = CatalogIndexState(watermark: nil, fingerprints: Self.map([Self.row(1), Self.row(2), Self.row(3), Self.row(11)]))
        let afterBatch3 = CatalogIndexState(watermark: "W", fingerprints: Self.map(snapshot))
        #expect(fake.committedIndexStates == [afterBatch1, afterBatch2, afterBatch3])
        #expect(summary == ReindexSummary(upserted: 3, removed: 2))
        #expect(try await indexer.indexedWatermark() == "W")
    }

    @Test func failureOnALaterBatchWithholdsWatermarkAndKeepsRemovesReDerivable() async throws {
        // A throw AFTER an earlier batch already committed must leave the watermark
        // un-advanced (so the next poll re-fetches) while the committed map reflects
        // exactly the work the index made durable — including the still-pending
        // removes, so the next run re-derives them rather than stranding the ids.
        let removedRows = [Self.row(10), Self.row(11)]
        // Fail the 2nd indexItems call, after batch 1 has committed.
        let fake = FakeSearchableIndex(
            initialClientState: Self.seed(rows: removedRows, watermark: "OLD"),
            failIndexItemsOnCall: 2
        )
        let indexer = SpotlightCatalogIndexer(index: fake, chunkSize: 2)

        await #expect(throws: FakeSearchableIndex.FakeError.self) {
            try await indexer.reindex(snapshot: Self.numberedRows(5), watermark: "NEW")
        }

        // Exactly one (intermediate) commit landed: batch 1's upserts {1,2} folded
        // onto the old map, watermark withheld. The pending removes {10,11} are
        // still in the committed map, so the retry re-derives them.
        let afterBatch1 = CatalogIndexState(
            watermark: nil,
            fingerprints: Self.map([Self.row(1), Self.row(2)] + removedRows)
        )
        #expect(fake.committedIndexStates == [afterBatch1])
        #expect(try await indexer.indexedWatermark() == nil)
    }

    @Test func midRunCrashThenShrunkExportDeletesAppliedRowsNotInNewExport() async throws {
        // Regression for the multi-batch crash + CHANGED-export hole: a batch's
        // endBatch durably applies its work, so the committed map must reflect that
        // — otherwise a crash mid-run followed by an export that DROPS an
        // already-applied row strands it (the next run's diff can't see it).
        //
        // Run 1: first-ever index of {1..5} at chunkSize 2; batch 1 applies {1,2}
        // then batch 2's indexItems crashes. Run 2 (fresh indexer, same persisted
        // state) gets a SHRUNK export {1} only — id 2 (applied in run 1) must be
        // deleted, not stranded.
        let crashed = FakeSearchableIndex(failIndexItemsOnCall: 2)   // empty index, fail 2nd batch
        let indexer1 = SpotlightCatalogIndexer(index: crashed, chunkSize: 2)
        await #expect(throws: FakeSearchableIndex.FakeError.self) {
            try await indexer1.reindex(snapshot: Self.numberedRows(5), watermark: "W1")
        }
        // Batch 1 committed the cumulative map {1,2} (the rows it made durable),
        // with the watermark withheld.
        let survived = try #require(crashed.recording.committedClientState)
        let survivedState = try #require(CatalogIndexState(decoding: survived))
        #expect(survivedState.watermark == nil)
        #expect(survivedState.fingerprints.keys.sorted() == [1, 2])

        // Run 2: fresh handle over the survived state; the catalog shrank to {1}.
        let recovered = FakeSearchableIndex(initialClientState: survived)
        let indexer2 = SpotlightCatalogIndexer(index: recovered)
        let summary = try await indexer2.reindex(snapshot: [Self.row(1)], watermark: "W2")

        // id 2 was applied in the crashed run and is gone from the new export → it
        // is deleted (with the old store-derived oldMap it would have been stranded).
        #expect(recovered.recording.deletedIdentifiers == ["album.2"])
        #expect(summary == ReindexSummary(upserted: 0, removed: 1))
        #expect(recovered.committedIndexState?.fingerprints.keys.sorted() == [1])
        #expect(recovered.committedIndexState?.watermark == "W2")
    }

    @Test func throwOnSingleBatchLeavesPriorStateIntact() async throws {
        // Single-batch failure: the prior committed state (OLD map + watermark)
        // must remain readable, so a fresh indexer recovers on the next run.
        let indexed = Self.numberedRows(2)
        let fake = FakeSearchableIndex(
            initialClientState: Self.seed(rows: indexed, watermark: "OLD-WATERMARK"),
            failOn: .endBatch
        )
        let indexer = SpotlightCatalogIndexer(index: fake)

        await #expect(throws: FakeSearchableIndex.FakeError.self) {
            // A real change so there IS work in the single batch.
            try await indexer.reindex(snapshot: [Self.row(1, albumTitle: "x"), Self.row(2)], watermark: "NEW")
        }

        #expect(fake.recording.endCount == 0)
        #expect(try await indexer.indexedWatermark() == "OLD-WATERMARK")
    }

    // MARK: Chunk-cap bounding

    @Test func boundsEachBatchAtChunkSizeAcrossManyUpserts() async throws {
        // Core Spotlight caps a single batch at 32,767 items; each chunk must close
        // its own batch. 5 first-ever adds at chunkSize 2 -> bounded batches 2,2,1.
        let fake = FakeSearchableIndex()
        let indexer = SpotlightCatalogIndexer(index: fake, chunkSize: 2)

        try await indexer.reindex(snapshot: Self.numberedRows(5), watermark: "W")

        let rec = fake.recording
        #expect(rec.beginCount == 3 && rec.endCount == 3)
        #expect(rec.indexBatchSizes == [2, 2, 1])
        #expect(rec.indexBatchSizes.allSatisfy { $0 <= 2 })
    }

    @Test func boundsTheDeleteSetAtChunkSizeToo() async throws {
        // A large vanish set (e.g. a catalog re-keying) must chunk like the
        // upserts — deletes count against the same per-batch cap. Old map
        // {1..5}; snapshot keeps only id 1, so 2,3,4,5 vanish.
        let indexed = Self.numberedRows(5)
        let fake = FakeSearchableIndex(initialClientState: Self.seed(rows: indexed, watermark: "OLD"))
        let indexer = SpotlightCatalogIndexer(index: fake, chunkSize: 2)

        let summary = try await indexer.reindex(snapshot: [Self.row(1)], watermark: "W")

        let rec = fake.recording
        #expect(rec.indexBatchSizes.isEmpty)            // id 1 unchanged: no upserts
        #expect(rec.deletedIdentifiers == ["album.2", "album.3", "album.4", "album.5"])
        // Deletes packed ≤2/batch: one deleteItems([2,3]) in batch 1, one
        // deleteItems([4,5]) in batch 2 — `deletedInBatch` records the batch number
        // per call, so two bounded batches read as [1, 2].
        #expect(rec.deletedInBatch == [1, 2])
        #expect(rec.beginCount == 2 && rec.endCount == 2)
        #expect(summary == ReindexSummary(upserted: 0, removed: 4))
        #expect(try await indexer.indexedWatermark() == "W")
    }

    // MARK: Edge cases

    @Test func emptySnapshotWithEmptyMapOpensOneEmptyBatch() async throws {
        // The service guards an empty 200 (skippedEmptyExport), but the indexer
        // stays robust: an empty snapshot against an empty map commits once.
        let fake = FakeSearchableIndex()
        let indexer = SpotlightCatalogIndexer(index: fake)

        let summary = try await indexer.reindex(snapshot: [], watermark: "w")

        let rec = fake.recording
        #expect(rec.beginCount == 1 && rec.endCount == 1)
        #expect(rec.indexBatchSizes.isEmpty)
        #expect(rec.deletedIdentifiers.isEmpty)
        #expect(summary == ReindexSummary(upserted: 0, removed: 0))
        #expect(fake.committedIndexState?.watermark == "w")
    }

    @Test func unreadableClientStateIsTreatedAsEmptyAndRebuilds() async throws {
        // A legacy issue-#19 bare-watermark blob (or any non-decodable state) must
        // degrade to a from-scratch reindex — every row an add, nothing to remove
        // — rather than crash or misparse.
        let fake = FakeSearchableIndex(initialClientState: Data("Mon, 01 Jun 2026 12:00:00 GMT".utf8))
        let indexer = SpotlightCatalogIndexer(index: fake)

        #expect(try await indexer.indexedWatermark() == nil)   // legacy blob reads as empty
        let summary = try await indexer.reindex(snapshot: Self.numberedRows(2), watermark: "W")

        #expect(fake.recording.indexedItems.map(\.identifier) == ["album.1", "album.2"])
        #expect(summary == ReindexSummary(upserted: 2, removed: 0))
        #expect(fake.committedIndexState?.watermark == "W")
    }
}
