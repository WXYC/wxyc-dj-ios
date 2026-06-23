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
        return Int(identifier.dropFirst(itemIdentifierPrefix.count))
    }

    /// The `CSSearchableItem` mirroring `row`: `title` = album, `contentDescription`
    /// = artist (plus the shelf call number when present), with `artist`/`album`/
    /// `keywords` set so home-screen search matches on artist, album, label, or
    /// call number. Pure — builds a value, talks to no index.
    public static func searchableItem(for row: CatalogRow) -> CSSearchableItem {
        let attributes = CSSearchableItemAttributeSet(contentType: .content)
        attributes.title = row.albumTitle
        let callNumber = row.callNumber
        attributes.contentDescription = callNumber.isEmpty
            ? row.artistName
            : "\(row.artistName) · \(callNumber)"
        attributes.artist = row.artistName
        attributes.album = row.albumTitle
        attributes.keywords = [row.artistName, row.albumTitle, row.label]
            .compactMap { $0 }
            .filter { !$0.isEmpty }
        return CSSearchableItem(
            uniqueIdentifier: itemIdentifier(row.id),
            domainIdentifier: domainIdentifier,
            attributeSet: attributes
        )
    }
}
