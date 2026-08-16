//
//  SQLiteBinStoreTests.swift
//  WXYCAPITests
//
//  Tests the per-DJ bin snapshot store (issue #60): wholesale-replace save,
//  snapshot round-trip across close/reopen, and the snapshot-present marker that
//  distinguishes a never-written store (nil) from a written-but-empty one ([]).
//
//  Created by Jake on 06/28/26.
//  Copyright © 2026 WXYC. All rights reserved.
//

import Foundation
import Testing
@testable import WXYCAPI

@Suite("SQLiteBinStore")
struct SQLiteBinStoreTests {
    // MARK: Fixtures / helpers

    /// The two WXYC-representative bin entries, decoded from the bundle's wire
    /// fixture so the projection is defined in exactly one place — Juana Molina
    /// (album 100) and Jessica Pratt (album 200), keyed like the bin itself by
    /// album id.
    static func entries() throws -> (juana: BinEntry, pratt: BinEntry) {
        let decoded = try Fixtures.binEntries()
        return (
            juana: try #require(decoded.first { $0.albumId == 100 }),
            pratt: try #require(decoded.first { $0.albumId == 200 })
        )
    }

    /// Run `body` against a store at a fresh, unique temp path, then close it
    /// (the inner `do` releases the actor, whose `Connection` deinit closes the
    /// handle) *before* the `defer` deletes the file — so teardown never unlinks
    /// the database out from under a live connection.
    static func withStore(
        _ body: (SQLiteBinStore) async throws -> Void
    ) async throws {
        let url = tempURL()
        defer { removeFile(url) }
        do {
            let store = try SQLiteBinStore(url: url)
            try await body(store)
        }
    }

    static func tempURL() -> URL {
        FileManager.default.temporaryDirectory
            .appending(path: "bin-store-test-\(UUID().uuidString).sqlite")
    }

    /// Remove the database and any SQLite sidecar (`-journal`/`-wal`/`-shm` —
    /// hyphen-suffixed on the same path, not a `.journal` path extension).
    static func removeFile(_ url: URL) {
        let fm = FileManager.default
        try? fm.removeItem(at: url)
        let base = url.path(percentEncoded: false)
        for suffix in ["-journal", "-wal", "-shm"] {
            try? fm.removeItem(at: URL(filePath: base + suffix))
        }
    }

    static func sortedByID(_ entries: [BinEntry]) -> [BinEntry] {
        entries.sorted { $0.id < $1.id }
    }

    // MARK: Tests

    @Test func saveThenSnapshotRoundTripsEntries() async throws {
        let (juana, pratt) = try Self.entries()
        try await Self.withStore { store in
            try await store.saveSnapshot([juana, pratt])
            let snapshot = try await store.snapshot()
            #expect(snapshot.map(Self.sortedByID) == [juana, pratt])
        }
    }

    @Test func neverWrittenStoreReturnsNil() async throws {
        try await Self.withStore { store in
            let snapshot = try await store.snapshot()
            #expect(snapshot == nil)
        }
    }

    @Test func writtenEmptySnapshotReturnsEmptyArrayNotNil() async throws {
        try await Self.withStore { store in
            try await store.saveSnapshot([])
            // The snapshot-present marker distinguishes "wrote an empty bin"
            // (== []) from "never wrote" (== nil).
            #expect(try await store.snapshot() == [])
        }
    }

    @Test func saveSnapshotIsWholesaleReplace() async throws {
        let (juana, pratt) = try Self.entries()
        try await Self.withStore { store in
            try await store.saveSnapshot([juana, pratt])
            // A second save with fewer rows drops the rest, not merges.
            try await store.saveSnapshot([pratt])
            #expect(try await store.snapshot() == [pratt])
        }
    }

    @Test func persistsSnapshotAcrossLaunches() async throws {
        let (juana, pratt) = try Self.entries()
        let url = Self.tempURL()
        defer { Self.removeFile(url) }

        // First "launch": write, then drop the store (closing the connection).
        do {
            let store = try SQLiteBinStore(url: url)
            try await store.saveSnapshot([juana, pratt])
        }

        // Second "launch": a brand-new store at the same path sees committed data.
        do {
            let reopened = try SQLiteBinStore(url: url)
            let snapshot = try await reopened.snapshot()
            #expect(snapshot.map(Self.sortedByID) == [juana, pratt])
        }
    }

    /// The store is keyed by album id and inserts with a plain `INSERT`, so a
    /// repeated album fails the save and rolls the whole transaction back —
    /// including the rows that were fine. This is the fail-closed posture the
    /// catalog store uses, and it is *why* every caller must run
    /// `BinEntry.deduplicatedByAlbum` first (the `/djs/bin` projection omits
    /// `track_title`, so one album binned under two tracks arrives twice).
    /// Pinned here, at the constraint, so a future writer can't discover it the
    /// hard way by losing a snapshot.
    @Test func duplicateAlbumIdsFailTheSaveAndKeepTheLastGoodSnapshot() async throws {
        let (juana, pratt) = try Self.entries()
        try await Self.withStore { store in
            try await store.saveSnapshot([juana, pratt])

            await #expect(throws: BinStoreError.self) {
                try await store.saveSnapshot([juana, juana])
            }

            // Rolled back: the previous snapshot is intact, not half-written.
            let snapshot = try await store.snapshot()
            #expect(snapshot.map(Self.sortedByID) == [juana, pratt])
        }
    }

    /// The dedupe callers are required to run produces exactly the input the
    /// store accepts, preserving first-seen order.
    @Test func deduplicatedByAlbumCollapsesRepeatsInFirstSeenOrder() async throws {
        let (juana, pratt) = try Self.entries()
        let deduped = BinEntry.deduplicatedByAlbum([pratt, juana, pratt])
        #expect(deduped == [pratt, juana])
        try await Self.withStore { store in
            try await store.saveSnapshot(deduped)
            #expect(try await store.snapshot()?.count == 2)
        }
    }

    @Test func emptyAfterNonEmptyReplacePersistsAsEmptyNotNil() async throws {
        let (juana, pratt) = try Self.entries()
        try await Self.withStore { store in
            try await store.saveSnapshot([juana, pratt])
            try await store.saveSnapshot([])
            // Replacing a populated bin with an empty one stays [] (marker still
            // present), never regressing to the never-written nil.
            #expect(try await store.snapshot() == [])
        }
    }
}
