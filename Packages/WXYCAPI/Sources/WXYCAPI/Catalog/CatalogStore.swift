//
//  CatalogStore.swift
//  WXYCAPI
//
//  Protocol for the id-keyed on-device catalog clone (issue #19 step 2): an
//  O(1) id->row lookup for the Spotlight deep link and an atomic whole-catalog
//  replace gated by the verbatim Last-Modified watermark. A protocol so the
//  shared CatalogRefreshService (step 4) can be tested against a spy.
//
//  Created by Jake on 06/22/26.
//  Copyright © 2026 WXYC. All rights reserved.
//

import Foundation

/// An id-keyed, persistent clone of the WXYC catalog (`GET /library/catalog`,
/// BS#1468). The store holds whatever rows the last successful `200` carried,
/// plus the verbatim `Last-Modified` string from that fetch as a watermark.
///
/// `Sendable` because the shared `CatalogRefreshService` (issue #19 step 4) and
/// the background reindex run off the main actor.
///
/// The store is now purely the **deep-link read model** plus the **replace
/// target**: issue #36 moved the Spotlight diff index-side (the indexer diffs the
/// in-memory export snapshot against its own fingerprint map), retiring the
/// `ids()` and `rows(after:limit:)` primitives the issue-#19 store-paging reindex
/// needed.
public protocol CatalogStore: Sendable {
    /// The cloned row for `id`, or `nil` if absent. O(1) for the deep-link path.
    func row(id: Int) async throws -> CatalogRow?

    /// Number of cloned rows.
    func count() async throws -> Int

    /// The verbatim `Last-Modified` string from the last `200`, or `nil` if the
    /// store has never been populated (or the server omitted the header).
    func lastModified() async throws -> String?

    /// Atomically replace the entire catalog and the watermark in one
    /// transaction: on a `200`, the new `rows` wholesale-replace the old set and
    /// `lastModified` becomes the new watermark (`nil` clears it). On any failure
    /// the transaction rolls back, leaving the previous clone intact. A `304`
    /// performs **no** call here — the caller keeps the existing clone untouched.
    ///
    /// The full-text index (issue #58) is rebuilt **inside the same
    /// transaction**, so it can never drift from the rows it indexes.
    func replace(rows: [CatalogRow], lastModified: String?) async throws

    /// Artist / album / call-number full-text search over the clone (issue #58),
    /// for the offline search fallback. Returns matching cloned ``CatalogRow``s
    /// (the caller maps each to an `AlbumSearchResult` via
    /// ``CatalogRow/detailFallback``). An empty or whitespace-only `query`
    /// returns `[]`. Results are in best-effort relevance order (FTS5 `bm25`
    /// rank), capped at `limit`. Track titles are **not** indexed — the clone
    /// carries none — so offline track-title search is out of scope.
    func search(query: String, limit: Int) async throws -> [CatalogRow]
}
