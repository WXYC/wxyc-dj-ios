//
//  CatalogSpotlight.swift
//  WXYCAPI
//
//  Core Spotlight identifier scheme + CatalogRow -> CSSearchableItem mapping for
//  the on-device catalog index (issue #19 step 3). One home for the "album.<id>"
//  key and the "catalog" domain, so the indexer (here) and the step-7 deep-link
//  parse share a single source of truth.
//
//  Created by Jake on 06/23/26.
//  Copyright © 2026 WXYC. All rights reserved.
//

import CoreSpotlight
import Foundation
import UniformTypeIdentifiers

/// Namespacing constants and pure mappings tying a ``CatalogRow`` to its Core
/// Spotlight representation. No state, no daemon calls — host-testable under
/// `swift test` (constructing a `CSSearchableItem` needs no Spotlight daemon).
public enum CatalogSpotlight {
    /// The `domainIdentifier` every cloned catalog item carries, so the index
    /// can scope catalog items as a group. The shared station library is
    /// non-sensitive, so this domain needs no sign-out cleanup (ADR-0005).
    public static let domainIdentifier = "catalog"

    /// The name of the client-owned `CSSearchableIndex` the catalog is mirrored
    /// into (issue #19 step 5). A **named** index, not `CSSearchableIndex.default()`:
    /// the `beginBatch` / `endBatch(withClientState:)` / `fetchLastClientState`
    /// API the indexer drives is unsupported on the shared default index. Items
    /// indexed into a named index still surface in home-screen search.
    public static let indexName = "org.wxyc.dj.catalog"

    private static let itemIdentifierPrefix = "album."

    /// The stable `uniqueIdentifier` for an album row — `"album.<id>"`. Stable
    /// across refreshes so a re-index *upserts* (never duplicates) the item, and
    /// it is the inverse of ``albumID(from:)`` (step 7's deep link parses it back).
    public static func itemIdentifier(_ albumID: Int) -> String {
        "\(itemIdentifierPrefix)\(albumID)"
    }

    /// The album id carried by a Spotlight item identifier, or `nil` if the
    /// string isn't exactly `"album.<Int>"`. Inverse of ``itemIdentifier(_:)``;
    /// step 7's `CSSearchableItemActionType` continuation uses it to route a tap.
    public static func albumID(from identifier: String) -> Int? {
        guard identifier.hasPrefix(itemIdentifierPrefix) else { return nil }
        let digits = identifier.dropFirst(itemIdentifierPrefix.count)
        // Require non-empty ASCII digits only. `Int(_:)` alone also accepts a
        // leading "+"/"-" (e.g. "album.-5" -> -5), which `itemIdentifier(_:)`
        // never emits — so this stays the exact inverse and rejects a malformed
        // identifier rather than routing a tap to a bogus (negative) id.
        guard !digits.isEmpty, digits.allSatisfy({ $0.isASCII && $0.isNumber }) else { return nil }
        return Int(digits)
    }

    /// The `CSSearchableItem` mirroring `row`: `title` = album (the field Spotlight
    /// reliably matches free-text queries against), `contentDescription` = artist
    /// (plus the shelf call number when present) as the human-readable subtitle,
    /// and `keywords` = artist, album, label, and call number so a query on any of
    /// those can match. The searchable terms live in `title`/`keywords` precisely
    /// because `contentDescription` is display-only — Core Spotlight does not match
    /// queries against it — so a call number kept only there would be unfindable.
    /// Pure — builds a value, talks to no index.
    public static func searchableItem(for row: CatalogRow) -> CSSearchableItem {
        let attributes = CSSearchableItemAttributeSet(contentType: .content)
        attributes.title = row.albumTitle
        let callNumber = row.callNumber
        attributes.contentDescription = callNumber.isEmpty
            ? row.artistName
            : "\(row.artistName) · \(callNumber)"
        attributes.artist = row.artistName
        attributes.album = row.albumTitle
        // Call number is included here so a shelf-code query matches — it is
        // otherwise only in the display-only `contentDescription`. Empty/nil
        // fields are dropped.
        attributes.keywords = [row.artistName, row.albumTitle, row.label, callNumber]
            .compactMap { $0 }
            .filter { !$0.isEmpty }
        return CSSearchableItem(
            uniqueIdentifier: itemIdentifier(row.id),
            domainIdentifier: domainIdentifier,
            attributeSet: attributes
        )
    }
}
