//
//  SpyCatalogStore.swift
//  WXYCAPITests
//
//  A functional, recording CatalogStore double for the CatalogRefreshService
//  tests (issue #19 step 4). Holds rows in a dict so row(id:)/count() behave like
//  the real store, and records every replace(rows:lastModified:) so the
//  decision-logic tests can assert what (if anything) the service wrote. A
//  lock-guarded Sendable class, matching FakeSearchableIndex.
//
//  Created by Jake on 06/23/26.
//  Copyright © 2026 WXYC. All rights reserved.
//

import Foundation
import os
@testable import WXYCAPI

final class SpyCatalogStore: CatalogStore {
    /// One recorded `replace`, lifted to a Sendable, assertable shape.
    struct ReplaceCall: Sendable, Equatable {
        let rowIDs: [Int]
        let lastModified: String?
    }

    private struct State {
        var rows: [Int: CatalogRow]
        var watermark: String?
        var replaceCalls: [ReplaceCall] = []
    }

    private let state: OSAllocatedUnfairLock<State>

    /// Seed the store with `rows` (the "previously cloned" set the step-4 diff
    /// subtracts the new export from) and an optional watermark.
    init(rows: [CatalogRow] = [], watermark: String? = nil) {
        var dict: [Int: CatalogRow] = [:]
        for row in rows { dict[row.id] = row }
        state = OSAllocatedUnfairLock(initialState: State(rows: dict, watermark: watermark))
    }

    var replaceCalls: [ReplaceCall] { state.withLock { $0.replaceCalls } }

    // MARK: CatalogStore

    func row(id: Int) -> CatalogRow? { state.withLock { $0.rows[id] } }

    func count() -> Int { state.withLock { $0.rows.count } }

    func lastModified() -> String? { state.withLock { $0.watermark } }

    func replace(rows: [CatalogRow], lastModified: String?) {
        state.withLock { st in
            var dict: [Int: CatalogRow] = [:]
            for row in rows { dict[row.id] = row }
            st.rows = dict
            st.watermark = lastModified
            st.replaceCalls.append(ReplaceCall(rowIDs: rows.map(\.id).sorted(), lastModified: lastModified))
        }
    }

    /// A simple diacritic-insensitive substring filter over artist / album /
    /// call number — enough fidelity for the `LibrarySearch` orchestrator tests,
    /// which only assert *which* store served the results, not FTS ranking. An
    /// empty/whitespace query returns `[]`, matching the real store and
    /// ``FTSQuery``. Results are id-ordered for determinism, capped at `limit`.
    func search(query: String, limit: Int) -> [CatalogRow] {
        let needle = query.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: nil)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !needle.isEmpty else { return [] }
        return state.withLock { st in
            st.rows.values
                .filter { row in
                    let haystack = [row.artistName, row.albumTitle, row.callNumber]
                        .joined(separator: " ")
                        .folding(options: [.diacriticInsensitive, .caseInsensitive], locale: nil)
                    return haystack.contains(needle)
                }
                .sorted { $0.id < $1.id }
                .prefix(limit)
                .map { $0 }
        }
    }
}
