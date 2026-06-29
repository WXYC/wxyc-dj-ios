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

    /// Two WXYC-representative bin entries (Juana Molina id 1, Jessica Pratt
    /// id 2). Whole-second `addedAt` values so the `.iso8601` encode / lenient
    /// decode round-trip is exact.
    static let juana = BinEntry(
        id: 1, djId: 42, albumId: 100,
        addedAt: Date(timeIntervalSince1970: 1_730_500_000),
        albumTitle: "DOGA", artistName: "Juana Molina",
        codeLetters: "MOL", codeNumber: 12
    )
    static let pratt = BinEntry(
        id: 2, djId: 42, albumId: 200,
        addedAt: Date(timeIntervalSince1970: 1_730_600_000),
        albumTitle: "On Your Own Love Again", artistName: "Jessica Pratt",
        codeLetters: "PRA", codeNumber: 5
    )

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
        try await Self.withStore { store in
            try await store.saveSnapshot([Self.juana, Self.pratt])
            let snapshot = try await store.snapshot()
            #expect(snapshot.map(Self.sortedByID) == [Self.juana, Self.pratt])
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
        try await Self.withStore { store in
            try await store.saveSnapshot([Self.juana, Self.pratt])
            // A second save with fewer rows drops the rest, not merges.
            try await store.saveSnapshot([Self.pratt])
            #expect(try await store.snapshot() == [Self.pratt])
        }
    }

    @Test func persistsSnapshotAcrossLaunches() async throws {
        let url = Self.tempURL()
        defer { Self.removeFile(url) }

        // First "launch": write, then drop the store (closing the connection).
        do {
            let store = try SQLiteBinStore(url: url)
            try await store.saveSnapshot([Self.juana, Self.pratt])
        }

        // Second "launch": a brand-new store at the same path sees committed data.
        do {
            let reopened = try SQLiteBinStore(url: url)
            let snapshot = try await reopened.snapshot()
            #expect(snapshot.map(Self.sortedByID) == [Self.juana, Self.pratt])
        }
    }

    @Test func emptyAfterNonEmptyReplacePersistsAsEmptyNotNil() async throws {
        try await Self.withStore { store in
            try await store.saveSnapshot([Self.juana, Self.pratt])
            try await store.saveSnapshot([])
            // Replacing a populated bin with an empty one stays [] (marker still
            // present), never regressing to the never-written nil.
            #expect(try await store.snapshot() == [])
        }
    }
}
