//
//  CatalogIndexState.swift
//  WXYCAPI
//
//  The Spotlight indexer's persisted record of what it currently holds (issue
//  #36): the verbatim Last-Modified watermark plus an id -> content-fingerprint
//  map. Rides Core Spotlight client state as one atomically-committed blob, so a
//  reindex can diff a fresh export against what the index last committed and
//  derive add/change/remove independently of the (already-replaced) store —
//  making the removed set crash-reproducible and the upserts delta-only.
//
//  Created by Jake on 06/24/26.
//  Copyright © 2026 WXYC. All rights reserved.
//

import Foundation

/// The Spotlight index's persisted self-knowledge, committed as Core Spotlight
/// client state on every successful reindex.
///
/// Two components, advanced together, atomically, on the final batch's
/// `endBatch(clientState:)`:
///
/// - ``watermark`` — the verbatim `Last-Modified` of the export the index last
///   fully committed. Sourced as the next poll's `If-Modified-Since`, so it
///   advances only when the whole reindex succeeds (the issue #19 step-4
///   crash-safety invariant).
/// - ``fingerprints`` — `album id -> content fingerprint` for every item the
///   index holds. The reindex diffs a fresh export against this map to derive
///   **add** (id absent), **change** (id present, fingerprint differs),
///   **remove** (in the map, absent from the export), and **unchanged** (equal
///   fingerprint, skipped). Deriving removes from *this* map — not from the
///   on-device store, which the refresh replaces before reindexing — is what
///   makes a vanished id's delete reproducible across a mid-reindex crash
///   (issue #36, limitation 1); skipping unchanged ids is what makes a typical
///   `200` cost `O(delta)` rather than re-upserting the whole catalog
///   (limitation 2).
///
/// Why a fingerprint **map**, not a bare id-set: a changed row keeps its id, so
/// an id-set diff classifies it as neither add nor remove and would never
/// re-upsert it, leaving Spotlight stale. The fingerprint is a *stable* digest
/// (``CatalogSpotlight/fingerprint(for:)``), never `CatalogRow`'s `hashValue` —
/// Swift salts `hashValue` per process, so it is unusable as a persisted token.
struct CatalogIndexState: Equatable, Sendable {
    /// The verbatim `Last-Modified` of the last fully-committed export, or `nil`
    /// if the index has never committed one (or an intermediate batch withheld
    /// it — see ``SpotlightCatalogIndexer``).
    var watermark: String?

    /// `album id -> content fingerprint` for every item the index holds.
    var fingerprints: [Int: UInt64]

    /// The empty state — never populated. Decoding an absent, legacy-format, or
    /// corrupt blob yields this, which forces the next reindex to re-fetch (nil
    /// watermark) and treat the whole export as adds.
    static let empty = CatalogIndexState(watermark: nil, fingerprints: [:])

    init(watermark: String?, fingerprints: [Int: UInt64]) {
        self.watermark = watermark
        self.fingerprints = fingerprints
    }

    // MARK: Binary codec

    /// Leading byte of every encoded blob, so a stale or foreign format (e.g. a
    /// blob written by the issue-#19 code, which stored a bare watermark string) is
    /// detected and rejected by ``init(decoding:)`` rather than misparsed.
    ///
    /// Bumping this **invalidates every persisted blob** — the migration lever for a
    /// change to the *mapping function* (`CatalogSpotlight.searchableItem(for:)`).
    /// Such a change alters every item's indexed representation but cannot move any
    /// row's `CatalogSpotlight.fingerprint(for:)` (the fingerprint covers row *data*,
    /// not the mapping), so the delta reindex would otherwise classify every already-
    /// indexed row as unchanged and skip it — the new representation would never land
    /// on an upgrade. A bump makes ``decodeWatermark(from:)`` and the full
    /// ``init(decoding:)`` read the old blob as `nil`/`empty`, so the next poll sends
    /// no `If-Modified-Since`, the server returns a full `200`, and the reindex
    /// re-upserts every row once against an empty map.
    ///
    /// Caveat: because that reindex diffs against an *empty* old map, it derives no
    /// removes — so an album that left the catalog during the prior format era (e.g.
    /// a record marked lost, dropped from the export) is re-indexed-as-absent but
    /// never deleted from the physical index, lingering as an orphaned Spotlight hit
    /// (a tap deep-links to a now-missing row, which `AlbumDetailView` surfaces as a
    /// fetch error). Accepted as rare and low-impact; the issue-#36 "no
    /// delete-by-domain" seam precludes a cheap reconciliation, and a reinstall
    /// clears it.
    ///
    /// Version history:
    /// - `1` — issue #36 initial codec (supersedes the issue-#19 bare-watermark blob).
    /// - `2` — issue #32 added `textContent` to `searchableItem(for:)`; bumped to
    ///   force a one-time full reindex so artist/label/call-number recall lands on
    ///   existing installs, not just fresh ones.
    private static let formatVersion: UInt8 = 2

    /// Encode to the compact, **stable** binary form committed as client state.
    /// Layout (all integers little-endian):
    ///
    /// ```
    /// [version: UInt8]   (the current ``formatVersion``)
    /// [watermark present: UInt8 (0 | 1)]
    /// if present: [UInt32 utf8 byte count][utf8 bytes]
    /// [UInt32 entry count]
    /// entry count × ([UInt64 id bit-pattern][UInt64 fingerprint])
    /// ```
    ///
    /// Entries are emitted in ascending-id order so the encoding is a pure
    /// function of the state (equal states encode byte-identically), which keeps
    /// the crash-recovery "re-derive the identical work set" reasoning simple.
    func encode() -> Data {
        var data = Data()
        data.appendLittleEndian(Self.formatVersion)
        if let watermark {
            data.appendLittleEndian(UInt8(1))
            let utf8 = Data(watermark.utf8)
            data.appendLittleEndian(UInt32(utf8.count))
            data.append(utf8)
        } else {
            data.appendLittleEndian(UInt8(0))
        }
        data.appendLittleEndian(UInt32(fingerprints.count))
        for id in fingerprints.keys.sorted() {
            data.appendLittleEndian(UInt64(bitPattern: Int64(id)))
            data.appendLittleEndian(fingerprints[id]!)
        }
        return data
    }

    /// Read a little-endian unsigned integer of type `T` from `bytes` at `offset`,
    /// advancing `offset`; `nil` if fewer than `T`'s bytes remain. The inverse of
    /// ``Data/appendLittleEndian(_:)`` — byte `i` carries bits `8*i`, so it agrees
    /// with the encoder on any host endianness.
    private static func readLittleEndian<T: FixedWidthInteger & UnsignedInteger>(
        _ type: T.Type, from bytes: [UInt8], at offset: inout Int
    ) -> T? {
        let size = MemoryLayout<T>.size
        guard offset + size <= bytes.count else { return nil }
        var value: T = 0
        for i in 0..<size {
            value |= T(bytes[offset + i]) << (8 * i)
        }
        offset += size
        return value
    }

    /// Parse the version + watermark prefix shared by the full decoder and the
    /// watermark-only fast path. Returns the watermark (itself `nil` when absent)
    /// and the offset where the entry table begins, or `nil` if the prefix is
    /// empty / wrong-version (e.g. the issue-#19 bare-watermark format) / malformed.
    private static func parsePrefix(_ bytes: [UInt8]) -> (watermark: String?, entriesOffset: Int)? {
        var offset = 0
        guard offset < bytes.count, bytes[offset] == formatVersion else { return nil }
        offset += 1
        guard offset < bytes.count else { return nil }
        let presence = bytes[offset]
        offset += 1
        switch presence {
        case 0:
            return (nil, offset)
        case 1:
            guard let length = readLittleEndian(UInt32.self, from: bytes, at: &offset),
                  offset + Int(length) <= bytes.count,
                  let watermark = String(bytes: bytes[offset..<offset + Int(length)], encoding: .utf8)
            else { return nil }
            offset += Int(length)
            return (watermark, offset)
        default:
            return nil
        }
    }

    /// Read **only** the watermark from an encoded blob, without decoding the
    /// (potentially ~1 MB) fingerprint map — the cheap read ``indexedWatermark()``
    /// needs on every poll and conditional GET. The watermark is encoded first
    /// precisely so this can stop before the entry table. Returns `nil` for an
    /// absent watermark **or** an unreadable prefix (both mean "no usable
    /// watermark; re-fetch"); it does not validate the entry table — a full
    /// ``init(decoding:)`` does that when the map itself is needed.
    static func decodeWatermark(from data: Data) -> String? {
        parsePrefix([UInt8](data)).flatMap { $0.watermark }
    }

    /// Decode a blob produced by ``encode()``. Returns `nil` for an empty,
    /// truncated, wrong-version (e.g. the issue-#19 bare-watermark format), or
    /// otherwise malformed blob; callers treat `nil` as ``empty`` and rebuild.
    /// Defensive by design — the index's own record being unreadable should
    /// degrade to a from-scratch reindex, never a crash.
    init?(decoding data: Data) {
        let bytes = [UInt8](data)
        guard let (watermark, entriesOffset) = Self.parsePrefix(bytes) else { return nil }
        var offset = entriesOffset
        guard let count = Self.readLittleEndian(UInt32.self, from: bytes, at: &offset) else { return nil }
        // Each entry is two UInt64s; reject a count the remaining bytes can't hold
        // BEFORE reserving, so a corrupt/oversized count (e.g. 0xFFFFFFFF on a short
        // blob) returns nil instead of OOM-trapping on reserveCapacity — the
        // defensive-decode contract. Compared in Int to avoid any UInt32 overflow.
        let entrySize = MemoryLayout<UInt64>.size * 2
        guard Int(count) <= (bytes.count - offset) / entrySize else { return nil }
        var fingerprints: [Int: UInt64] = [:]
        fingerprints.reserveCapacity(Int(count))
        for _ in 0..<count {
            guard let rawID = Self.readLittleEndian(UInt64.self, from: bytes, at: &offset),
                  let fingerprint = Self.readLittleEndian(UInt64.self, from: bytes, at: &offset) else { return nil }
            fingerprints[Int(Int64(bitPattern: rawID))] = fingerprint
        }

        self.init(watermark: watermark, fingerprints: fingerprints)
    }
}

private extension Data {
    /// Append `value`'s little-endian bytes — the one byte order both ends of the
    /// codec agree on, independent of host endianness.
    mutating func appendLittleEndian<T: FixedWidthInteger>(_ value: T) {
        var littleEndian = value.littleEndian
        Swift.withUnsafeBytes(of: &littleEndian) { append(contentsOf: $0) }
    }
}
