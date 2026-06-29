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
        try Fixtures.catalogRows()
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

    // MARK: Full-text search (issue #58)

    /// Nilüfer Yanya — the diacritic-bearing canonical name (id 300). The
    /// `remove_diacritics 2` tokenizer must fold "Nilüfer" so a plain-ASCII
    /// "nilufer" query still matches.
    static func niluferRow() -> CatalogRow {
        CatalogRow(
            id: 300, artistName: "Nilüfer Yanya", albumTitle: "Painless",
            codeLetters: "YAN", codeNumber: 2, codeArtistNumber: 1,
            label: "ATO Records", genreName: "Rock", formatName: "LP",
            onStreaming: true, plays: 8, artworkURL: nil,
            rotationBin: nil, rotationKillDate: nil
        )
    }

    /// Chuquimamani-Condori (id 400) with a call number whose letters ("ZZQ")
    /// appear in neither the artist nor the album, so a "zzq" query exercises the
    /// call_number index column unambiguously.
    static func chuquiRow() -> CatalogRow {
        CatalogRow(
            id: 400, artistName: "Chuquimamani-Condori", albumTitle: "Edits",
            codeLetters: "ZZQ", codeNumber: 3, codeArtistNumber: 1,
            label: "self-released", genreName: "Electronic", formatName: "LP",
            onStreaming: false, plays: 5, artworkURL: nil,
            rotationBin: nil, rotationKillDate: nil
        )
    }

    @Test func searchMatchesByArtistPrefix() async throws {
        let rows = try Self.fixtureRows()
        try await Self.withStore { store in
            try await store.replace(rows: rows, lastModified: nil)
            let hits = try await store.search(query: "juana", limit: 25)
            #expect(hits.map(\.id) == [100])
        }
    }

    @Test func searchMatchesByAlbumPrefix() async throws {
        let rows = try Self.fixtureRows()
        try await Self.withStore { store in
            try await store.replace(rows: rows, lastModified: nil)
            // "On Your Own Love Again" → token "love" matches the album column.
            let hits = try await store.search(query: "love", limit: 25)
            #expect(hits.map(\.id) == [200])
        }
    }

    @Test func searchIsDiacriticInsensitive() async throws {
        let rows = try Self.fixtureRows() + [Self.niluferRow()]
        try await Self.withStore { store in
            try await store.replace(rows: rows, lastModified: nil)
            let hits = try await store.search(query: "nilufer", limit: 25)
            #expect(hits.map(\.id) == [300])
        }
    }

    @Test func searchMatchesByCallNumber() async throws {
        let rows = try Self.fixtureRows() + [Self.chuquiRow()]
        try await Self.withStore { store in
            try await store.replace(rows: rows, lastModified: nil)
            let hits = try await store.search(query: "zzq", limit: 25)
            #expect(hits.map(\.id) == [400])
        }
    }

    @Test func searchReturnsFullRow() async throws {
        let rows = try Self.fixtureRows()
        try await Self.withStore { store in
            try await store.replace(rows: rows, lastModified: nil)
            let hits = try await store.search(query: "juana", limit: 25)
            // The match loads the stored BLOB, not just the indexed text — the
            // full CatalogRow round-trips so the caller can build a result.
            #expect(hits.first == rows[0])
        }
    }

    @Test func emptyQuerySearchReturnsEmpty() async throws {
        let rows = try Self.fixtureRows()
        try await Self.withStore { store in
            try await store.replace(rows: rows, lastModified: nil)
            #expect(try await store.search(query: "   ", limit: 25).isEmpty)
            #expect(try await store.search(query: "", limit: 25).isEmpty)
        }
    }

    @Test func punctuationOnlyQueryDoesNotThrowAndReturnsEmpty() async throws {
        let rows = try Self.fixtureRows()
        try await Self.withStore { store in
            try await store.replace(rows: rows, lastModified: nil)
            // The query builder quotes/escapes punctuation, so it can never
            // inject MATCH syntax — a punctuation-only query is a clean miss.
            #expect(try await store.search(query: "& \"", limit: 25).isEmpty)
        }
    }

    @Test func searchRespectsLimit() async throws {
        // Two rows whose albums both contain "love"; limit 1 returns one.
        let pratt = try Self.fixtureRows()[1]   // "On Your Own Love Again"
        let lover = CatalogRow(
            id: 500, artistName: "Stereolab", albumTitle: "Love Theme",
            codeLetters: "STE", codeNumber: 1, codeArtistNumber: 1,
            label: "Duophonic", genreName: "Electronic", formatName: "LP",
            onStreaming: true, plays: 20, artworkURL: nil,
            rotationBin: nil, rotationKillDate: nil
        )
        try await Self.withStore { store in
            try await store.replace(rows: [pratt, lover], lastModified: nil)
            #expect(try await store.search(query: "love", limit: 2).count == 2)
            #expect(try await store.search(query: "love", limit: 1).count == 1)
        }
    }

    @Test func replaceRebuildsIndexSoRemovedRowStopsMatching() async throws {
        let rows = try Self.fixtureRows()   // Juana (100), Jessica Pratt (200)
        try await Self.withStore { store in
            try await store.replace(rows: rows, lastModified: nil)
            #expect(try await store.search(query: "juana", limit: 25).map(\.id) == [100])

            // Drop Juana; the FTS index is rebuilt in the same transaction, so
            // the stale term can no longer match.
            try await store.replace(rows: [rows[1]], lastModified: nil)
            #expect(try await store.search(query: "juana", limit: 25).isEmpty)
            #expect(try await store.search(query: "pratt", limit: 25).map(\.id) == [200])
        }
    }
}
