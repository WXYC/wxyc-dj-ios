//
//  CatalogStore.swift
//  WXYCAPI
//
//  Protocol for the id-keyed on-device catalog clone (issue #19 steps 2-3): an
//  O(1) id->row lookup for the Spotlight deep link, an atomic whole-catalog
//  replace gated by the verbatim Last-Modified watermark, and a keyset-paginated
//  bulk read (rows(after:limit:)) the Spotlight indexer pages through. A protocol
//  so the shared CatalogRefreshService (step 4) can be tested against a spy.
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
public protocol CatalogStore: Sendable {
    /// The cloned row for `id`, or `nil` if absent. O(1) for the deep-link path.
    func row(id: Int) async throws -> CatalogRow?

    /// Number of cloned rows.
    func count() async throws -> Int

    /// The id set of every cloned row. The cheap diff primitive
    /// ``CatalogRefreshService`` (issue #19 step 4) subtracts the new export from
    /// to find the ids that vanished, which it hands to the indexer for targeted
    /// Spotlight deletes. Reads ids only — **no row-BLOB decode** — so it stays
    /// cheap on a tens-of-thousands-row catalog.
    func ids() async throws -> Set<Int>

    /// The verbatim `Last-Modified` string from the last `200`, or `nil` if the
    /// store has never been populated (or the server omitted the header).
    func lastModified() async throws -> String?

    /// A page of cloned rows ordered by ascending `id`, for the bulk Spotlight
    /// reindex (issue #19 step 3). Keyset pagination: returns up to `limit` rows
    /// whose `id` is greater than `after` (from the first row when `after` is
    /// `nil`); an empty result means the cursor reached the last row. Each call
    /// returns a bounded chunk and **releases the store between pages**, so the
    /// deep-link `row(id:)` lookup interleaves and the reindex never materializes
    /// the whole (tens-of-thousands-row) catalog at once. Advance the cursor to
    /// the last returned row's `id` to fetch the next page.
    func rows(after id: Int?, limit: Int) async throws -> [CatalogRow]

    /// Atomically replace the entire catalog and the watermark in one
    /// transaction: on a `200`, the new `rows` wholesale-replace the old set and
    /// `lastModified` becomes the new watermark (`nil` clears it). On any failure
    /// the transaction rolls back, leaving the previous clone intact. A `304`
    /// performs **no** call here — the caller keeps the existing clone untouched.
    func replace(rows: [CatalogRow], lastModified: String?) async throws
}
