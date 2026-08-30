//
//  CatalogStoreRowsTests.swift
//  WXYCAPITests
//
//  Pins CatalogStore.rows(ids:) — the digital-archive badge's one batch read
//  per search-result page (issue #136) — on both implementations: the
//  protocol-extension default (SpyCatalogStore, which doesn't override it) and
//  SQLiteCatalogStore's own `WHERE id IN (…)` override (SQLiteCatalogStoreTests).
//
//  Created by Jake on 08/29/26.
//  Copyright © 2026 WXYC. All rights reserved.
//

import Foundation
import Testing
@testable import WXYCAPI

@Suite("CatalogStore.rows(ids:) default")
struct CatalogStoreRowsTests {
    @Test func defaultImplementationLoopsRowLookupAndSkipsMisses() async throws {
        let rows = try Fixtures.catalogRows()
        let spy = SpyCatalogStore(rows: rows)

        let result = try await spy.rows(ids: [rows[0].id, rows[1].id, 999])

        #expect(result.count == 2)
        #expect(result[rows[0].id] == rows[0])
        #expect(result[rows[1].id] == rows[1])
        #expect(result[999] == nil)
    }

    @Test func defaultImplementationOnEmptyIdsReturnsEmpty() async throws {
        let rows = try Fixtures.catalogRows()
        let spy = SpyCatalogStore(rows: rows)

        #expect(try await spy.rows(ids: []).isEmpty)
    }
}
