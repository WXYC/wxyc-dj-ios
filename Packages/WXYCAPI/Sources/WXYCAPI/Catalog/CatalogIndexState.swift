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

    /// Leading byte of every encoded blob, so a future format change (or a blob
    /// written by the issue-#19 code, which stored a bare watermark string) is
    /// detected and rejected by ``init(decoding:)`` rather than misparsed.
    private static let formatVersion: UInt8 = 1

    /// Encode to the compact, **stable** binary form committed as client state.
    /// Layout (all integers little-endian):
    ///
    /// ```
    /// [version: UInt8 = 1]
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

    /// Decode a blob produced by ``encode()``. Returns `nil` for an empty,
    /// truncated, wrong-version (e.g. the issue-#19 bare-watermark format), or
    /// otherwise malformed blob; callers treat `nil` as ``empty`` and rebuild.
    /// Defensive by design — the index's own record being unreadable should
    /// degrade to a from-scratch reindex, never a crash.
    init?(decoding data: Data) {
        let bytes = [UInt8](data)
        var offset = 0

        func readUInt8() -> UInt8? {
            guard offset < bytes.count else { return nil }
            defer { offset += 1 }
            return bytes[offset]
        }
        func readFixedWidth<T: FixedWidthInteger & UnsignedInteger>(_ type: T.Type) -> T? {
            let size = MemoryLayout<T>.size
            guard offset + size <= bytes.count else { return nil }
            var value: T = 0
            for i in 0..<size {
                value |= T(bytes[offset + i]) << (8 * i)
            }
            offset += size
            return value
        }

        guard let version = readUInt8(), version == Self.formatVersion,
              let presence = readUInt8() else { return nil }

        var watermark: String?
        switch presence {
        case 0:
            watermark = nil
        case 1:
            guard let length = readFixedWidth(UInt32.self),
                  offset + Int(length) <= bytes.count,
                  let decoded = String(bytes: bytes[offset..<offset + Int(length)], encoding: .utf8)
            else { return nil }
            offset += Int(length)
            watermark = decoded
        default:
            return nil
        }

        guard let count = readFixedWidth(UInt32.self) else { return nil }
        var fingerprints: [Int: UInt64] = [:]
        fingerprints.reserveCapacity(Int(count))
        for _ in 0..<count {
            guard let rawID = readFixedWidth(UInt64.self),
                  let fingerprint = readFixedWidth(UInt64.self) else { return nil }
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
