//
//  SQLiteCatalogStoreTests.swift
//  WXYCAPITests
//
//  Tests the id-keyed on-device catalog store (issue #19 step 2): O(1) id->row
//  lookup, atomic whole-catalog replace on a 200, the verbatim Last-Modified
//  watermark, and cross-launch persistence.
//
//  Created by Jake on 06/22/26.
//  Copyright © 2026 WXYC. All rights reserved.
//

import Foundation
import Testing
@testable import WXYCAPI

@Suite("SQLiteCatalogStore")
struct SQLiteCatalogStoreTests {
    // MARK: Fixtures / helpers

    /// The two WXYC-representative export rows (Juana Molina id 100, Jessica
    /// Pratt id 200) decoded from the NDJSON wire fixture.
    static func fixtureRows() throws -> [CatalogRow] {
        try Fixtures.catalogNDJSON
            .split(separator: "\n")
            .map { try JSONCoders.decoder.decode(CatalogRow.self, from: Data($0.utf8)) }
    }

    /// Run `body` against a store at a fresh, unique temp path, then close it
    /// (the inner `do` releases the actor, whose `Connection` deinit closes the
    /// handle) *before* the `defer` deletes the file — so teardown never unlinks
    /// the database out from under a live connection.
    static func withStore(
        _ body: (SQLiteCatalogStore) async throws -> Void
    ) async throws {
        let url = tempURL()
        defer { removeFile(url) }
        do {
            let store = try SQLiteCatalogStore(url: url)
            try await body(store)
        }
    }

    static func tempURL() -> URL {
        FileManager.default.temporaryDirectory
            .appending(path: "catalog-store-test-\(UUID().uuidString).sqlite")
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

    // MARK: Tests

    @Test func idLookupReturnsStoredRowAndNilForMiss() async throws {
        let rows = try Self.fixtureRows()
        try await Self.withStore { store in
            try await store.replace(rows: rows, lastModified: nil)
            #expect(try await store.row(id: 100) == rows[0])
            #expect(try await store.row(id: 200) == rows[1])
            #expect(try await store.row(id: 999) == nil)
            #expect(try await store.count() == 2)
        }
    }

    @Test func replaceDropsVanishedRows() async throws {
        let rows = try Self.fixtureRows()
        let juana = rows[0]   // id 100
        let pratt = rows[1]   // id 200
        let chuqui = CatalogRow(
            id: 300, artistName: "Chuquimamani-Condori", albumTitle: "Edits",
            codeLetters: "CHU", codeNumber: 3, codeArtistNumber: 1,
            label: "self-released", genreName: "Electronic", formatName: "LP",
            onStreaming: false, plays: 5, artworkURL: nil,
            rotationBin: nil, rotationKillDate: nil
        )

        try await Self.withStore { store in
            try await store.replace(rows: [juana, pratt], lastModified: nil)
            try await store.replace(rows: [pratt, chuqui], lastModified: nil)

            #expect(try await store.row(id: 100) == nil)      // vanished
            #expect(try await store.row(id: 200) == pratt)    // retained
            #expect(try await store.row(id: 300) == chuqui)   // added
            #expect(try await store.count() == 2)
        }
    }

    @Test func persistsAndClearsWatermark() async throws {
        let rows = try Self.fixtureRows()
        let watermark = "Mon, 01 Jun 2026 12:00:00 GMT"

        try await Self.withStore { store in
            try await store.replace(rows: rows, lastModified: watermark)
            #expect(try await store.lastModified() == watermark)

            // A later 200 with no header clears it.
            try await store.replace(rows: rows, lastModified: nil)
            #expect(try await store.lastModified() == nil)
        }
    }

    @Test func persistsRowsAndWatermarkAcrossLaunches() async throws {
        let url = Self.tempURL()
        defer { Self.removeFile(url) }
        let rows = try Self.fixtureRows()
        let watermark = "Tue, 02 Jun 2026 09:30:00 GMT"

        // First "launch": write, then drop the store (closing the connection).
        do {
            let store = try SQLiteCatalogStore(url: url)
            try await store.replace(rows: rows, lastModified: watermark)
        }

        // Second "launch": a brand-new store at the same path sees committed data.
        do {
            let reopened = try SQLiteCatalogStore(url: url)
            #expect(try await reopened.row(id: 100) == rows[0])
            #expect(try await reopened.count() == 2)
            #expect(try await reopened.lastModified() == watermark)
        }
    }

    @Test func replaceRollsBackOnDuplicateIdLeavingPriorStateIntact() async throws {
        let rows = try Self.fixtureRows()

        try await Self.withStore { store in
            try await store.replace(rows: rows, lastModified: "good-watermark")

            // A torn export with a duplicate id must fail the whole replace, not
            // partially apply it — same fail-closed posture as the NDJSON parser.
            let dupA = rows[1]                                   // id 200
            let dupB = CatalogRow(
                id: 200, artistName: "dup", albumTitle: "dup",
                codeLetters: nil, codeNumber: nil, codeArtistNumber: nil,
                label: nil, genreName: nil, formatName: nil,
                onStreaming: nil, plays: nil, artworkURL: nil,
                rotationBin: nil, rotationKillDate: nil
            )

            await #expect(throws: (any Error).self) {
                try await store.replace(rows: [dupA, dupB], lastModified: "new-watermark")
            }

            // Prior contents and watermark survive the rolled-back replace.
            #expect(try await store.row(id: 100) == rows[0])
            #expect(try await store.count() == 2)
            #expect(try await store.lastModified() == "good-watermark")
        }
    }

    @Test func emptyReplaceEmptiesStoreAndWatermark() async throws {
        let rows = try Self.fixtureRows()

        try await Self.withStore { store in
            try await store.replace(rows: rows, lastModified: "w")

            try await store.replace(rows: [], lastModified: nil)

            #expect(try await store.count() == 0)
            #expect(try await store.row(id: 100) == nil)
            #expect(try await store.lastModified() == nil)
        }
    }
}
