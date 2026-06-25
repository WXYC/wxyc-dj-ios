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
import CryptoKit
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

    /// The album id carried by a Core Spotlight **continuation activity**, or
    /// `nil` if `activity` isn't a catalog-item tap. The system delivers an
    /// `NSUserActivity` of type `CSSearchableItemActionType` carrying the tapped
    /// item's `uniqueIdentifier` under `userInfo[CSSearchableItemActivityIdentifier]`;
    /// this guards the activity type, pulls that identifier, and parses it via
    /// ``albumID(from:)``. One home for the continuation parse so the
    /// `UIWindowSceneDelegate` (cold launch via `scene(_:willConnectTo:)`, warm
    /// via `scene(_:continue:)`) routes a tap through the exact same, unit-tested
    /// logic — the reliable replacement for the flaky view-level
    /// `onContinueUserActivity`, which was not delivering the activity on this app.
    public static func albumID(fromActivity activity: NSUserActivity) -> Int? {
        guard activity.activityType == CSSearchableItemActionType,
              let identifier = activity.userInfo?[CSSearchableItemActivityIdentifier] as? String
        else { return nil }
        return albumID(from: identifier)
    }

    /// The `CSSearchableItem` mirroring `row`: `title` / `displayName` = album (the
    /// field Spotlight reliably matches free-text queries against),
    /// `contentDescription` = artist (plus the shelf call number when present) as
    /// the human-readable subtitle, and `keywords` = artist, album, label, and call
    /// number so a query on any of those can match. The searchable terms live in
    /// `title`/`keywords` precisely because `contentDescription` is display-only —
    /// Core Spotlight does not match queries against it — so a call number kept only
    /// there would be unfindable.
    ///
    /// `displayName` is set alongside `title` deliberately: on iOS 17+ Core
    /// Spotlight rejects an item that has no `displayName` as an *invalid item*
    /// (`CSIndexErrorDomain` `-1001` `CSIndexErrorCodeInvalidItemError`), and since
    /// `indexSearchableItems` fails the whole batch on any invalid item, a single
    /// missing `displayName` leaves the entire catalog unindexed and home-screen
    /// search empty. Pure — builds a value, talks to no index.
    public static func searchableItem(for row: CatalogRow) -> CSSearchableItem {
        searchableItem(for: row, thumbnailData: nil)
    }

    /// As ``searchableItem(for:)`` but also embeds `thumbnailData` (a downscaled
    /// JPEG cover) as the item's Spotlight thumbnail (issue #44). Embedded bytes —
    /// not a `thumbnailURL` — so the index owns its own copy: eviction or
    /// container-path rotation can never dangle a live item's art (rdar://23592852),
    /// and a `nil` here is identical to the plain mapping (default icon). The bytes
    /// are read off the on-disk cache by the caller right before the upsert, keeping
    /// this mapping pure / synchronous / network-free.
    public static func searchableItem(for row: CatalogRow, thumbnailData: Data?) -> CSSearchableItem {
        let attributes = CSSearchableItemAttributeSet(contentType: .content)
        attributes.title = row.albumTitle
        attributes.displayName = row.albumTitle
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
        // nil leaves no thumbnail → the default icon, identical to the plain mapping.
        attributes.thumbnailData = thumbnailData
        return CSSearchableItem(
            uniqueIdentifier: itemIdentifier(row.id),
            domainIdentifier: domainIdentifier,
            attributeSet: attributes
        )
    }

    /// A **stable** content fingerprint over exactly the fields that feed
    /// ``searchableItem(for:)`` — so the indexer (issue #36) can tell, across
    /// process launches, whether a row's *indexed representation* changed and
    /// re-upsert only the rows that did.
    ///
    /// Fingerprinted fields: album title, artist, label, the call-number
    /// components (`codeLetters` / `codeNumber` / `codeArtistNumber`), and
    /// `artworkURL` (so an artwork-only change still re-upserts — required once
    /// Spotlight thumbnails land, issue #44). Deliberately **excludes** fields
    /// the searchable item ignores (`plays`, `genreName`, `formatName`,
    /// `onStreaming`, rotation): a change confined to those produces an identical
    /// `CSSearchableItem`, so re-upserting it would be wasted work. Keep this set
    /// in lockstep with ``searchableItem(for:)`` — a field that starts feeding
    /// the item but not the fingerprint would leave Spotlight stale on a change
    /// confined to it.
    ///
    /// **Not** `CatalogRow.hashValue`: Swift seeds `Hashable` with a per-process
    /// random salt, so `hashValue` differs run to run and is unusable as a
    /// persisted token. This is a SHA-256 digest truncated to 64 bits; for
    /// change detection the only event that matters is *the same id's* old vs.
    /// new content hashing equal despite differing (≈ 2⁻⁶⁴), which is negligible
    /// — cross-id collisions are irrelevant since fingerprints are only ever
    /// compared per id.
    static func fingerprint(for row: CatalogRow) -> UInt64 {
        var hasher = SHA256()
        // Length-prefix every field and mark nil distinctly, so field boundaries
        // are unambiguous ("AB"+"C" can't hash like "A"+"BC") and a nil never
        // hashes like an empty string. Over-sensitivity (nil vs "") is harmless
        // — a redundant re-upsert is idempotent — whereas under-sensitivity
        // would miss a real change.
        for field in [
            row.albumTitle,
            row.artistName,
            row.label,
            row.codeLetters,
            row.codeNumber.map(String.init),
            row.codeArtistNumber.map(String.init),
            row.artworkURL?.absoluteString,
        ] {
            if let field {
                let utf8 = Data(field.utf8)
                var length = UInt64(utf8.count).littleEndian
                Swift.withUnsafeBytes(of: &length) { hasher.update(bufferPointer: $0) }
                hasher.update(data: utf8)
            } else {
                // A length no real string can have, so nil ≠ "" (length 0).
                var sentinel = UInt64.max.littleEndian
                Swift.withUnsafeBytes(of: &sentinel) { hasher.update(bufferPointer: $0) }
            }
        }
        return hasher.finalize().prefix(8).reduce(UInt64(0)) { ($0 << 8) | UInt64($1) }
    }
}
