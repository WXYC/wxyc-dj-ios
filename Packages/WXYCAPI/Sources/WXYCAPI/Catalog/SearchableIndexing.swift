//
//  SearchableIndexing.swift
//  WXYCAPI
//
//  A narrow seam over the CSSearchableIndex batch API the catalog indexer drives
//  (issue #19 step 3), so SpotlightCatalogIndexer is unit-testable against a fake
//  under host `swift test` (no Spotlight daemon there) and the real index is
//  injected on-device.
//
//  Created by Jake on 06/23/26.
//  Copyright © 2026 WXYC. All rights reserved.
//

import CoreSpotlight
import Foundation

/// The Core Spotlight batch operations the catalog indexer needs, behind a
/// `Sendable` protocol so the indexer can be exercised against a fake. The SDK
/// auto-bridges each completion-handler method to `async throws`, so no manual
/// `withCheckedThrowingContinuation` is required.
///
/// Deliberately exposes **no delete-by-domain**: the only delete is by explicit
/// identifier, so an indexer using this seam *structurally cannot* empty
/// home-screen search mid-reindex.
public protocol SearchableIndexing: Sendable {
    /// Open a batch. Core Spotlight requires the caller to serialize access to
    /// the index between `beginBatch()` and the matching `endBatch(clientState:)`.
    func beginBatch()

    /// Upsert `items` — re-indexing an existing `uniqueIdentifier` updates it.
    func indexItems(_ items: [CSSearchableItem]) async throws

    /// Delete items by `uniqueIdentifier` — used only for ids that vanished from
    /// the catalog.
    func deleteItems(withIdentifiers identifiers: [String]) async throws

    /// Commit the batch, persisting `clientState` (the verbatim `Last-Modified`
    /// watermark) as the index's resume state.
    func endBatch(clientState: Data) async throws

    /// The client state committed by the last successful `endBatch`, or `nil`
    /// when the index has never been populated.
    func lastClientState() async throws -> Data?
}

/// The production conformer over a real `CSSearchableIndex` (e.g. `.default()`).
///
/// `@unchecked Sendable`: `CSSearchableIndex` is neither `Sendable` nor
/// thread-safe in batch mode, but the catalog indexer drives exactly one
/// sequential reindex at a time (step 4 guarantees no overlapping refresh), which
/// satisfies Core Spotlight's "client serializes batch access" contract. The
/// stored reference is otherwise immutable.
public struct RealSearchableIndex: SearchableIndexing, @unchecked Sendable {
    private let index: CSSearchableIndex

    public init(_ index: CSSearchableIndex) {
        self.index = index
    }

    public func beginBatch() {
        index.beginBatch()
    }

    public func indexItems(_ items: [CSSearchableItem]) async throws {
        try await index.indexSearchableItems(items)
    }

    public func deleteItems(withIdentifiers identifiers: [String]) async throws {
        try await index.deleteSearchableItems(withIdentifiers: identifiers)
    }

    public func endBatch(clientState: Data) async throws {
        try await index.endBatch(withClientState: clientState)
    }

    public func lastClientState() async throws -> Data? {
        try await index.fetchLastClientState()
    }
}
