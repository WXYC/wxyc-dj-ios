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
        let url = CatalogStoreTestSupport.tempStoreURL()
        defer { CatalogStoreTestSupport.removeStoreFile(url) }
        do {
            let store = try SQLiteCatalogStore(url: url)
            try await body(store)
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
        let url = CatalogStoreTestSupport.tempStoreURL()
        defer { CatalogStoreTestSupport.removeStoreFile(url) }
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

    // MARK: rows(after:limit:) — the step-3 keyset bulk read

    /// Keyset boundaries in one place: a first page from the start, a mid-catalog
    /// page after a cursor, and a cursor past the last id. Seeds 10 shuffled rows
    /// so the ascending-id result also proves the SELECT orders by id.
    @Test(arguments: [
        (after: nil, limit: 3, expectedIDs: [1, 2, 3]),
        (after: 3, limit: 3, expectedIDs: [4, 5, 6]),
        (after: 10, limit: 5, expectedIDs: []),
    ] as [(after: Int?, limit: Int, expectedIDs: [Int])])
    func pageReturnsExpectedAscendingRows(_ page: (after: Int?, limit: Int, expectedIDs: [Int])) async throws {
        try await Self.withStore { store in
            try await store.replace(rows: CatalogStoreTestSupport.numberedRows(10, shuffled: true), lastModified: nil)
            #expect(try await store.rows(after: page.after, limit: page.limit).map(\.id) == page.expectedIDs)
        }
    }

    @Test func nonPositiveLimitReturnsEmpty() async throws {
        let rows = CatalogStoreTestSupport.numberedRows(5, shuffled: true)
        try await Self.withStore { store in
            try await store.replace(rows: rows, lastModified: nil)
            #expect(try await store.rows(after: nil, limit: 0).isEmpty)
        }
    }

    @Test func fullSweepConcatenatesEveryRowInIdOrder() async throws {
        let rows = CatalogStoreTestSupport.numberedRows(7, shuffled: true)
        try await Self.withStore { store in
            try await store.replace(rows: rows, lastModified: nil)
            var swept: [CatalogRow] = []
            var cursor: Int? = nil
            while true {
                let page = try await store.rows(after: cursor, limit: 2)
                if page.isEmpty { break }
                swept.append(contentsOf: page)
                cursor = page.last?.id
            }
            #expect(swept.map(\.id) == Array(1...7))
        }
    }

    @Test func idLookupInterleavesWithPagedSweep() async throws {
        // The store releases between pages, so a deep-link lookup resolves
        // mid-sweep rather than blocking behind the whole reindex.
        let rows = CatalogStoreTestSupport.numberedRows(6, shuffled: true)
        try await Self.withStore { store in
            try await store.replace(rows: rows, lastModified: nil)
            let firstPage = try await store.rows(after: nil, limit: 2)
            #expect(firstPage.map(\.id) == [1, 2])
            #expect(try await store.row(id: 5)?.id == 5)
            let nextPage = try await store.rows(after: firstPage.last?.id, limit: 2)
            #expect(nextPage.map(\.id) == [3, 4])
        }
    }
}
