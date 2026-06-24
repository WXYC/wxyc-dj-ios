//
//  CatalogIndexStateTests.swift
//  WXYCAPITests
//
//  Tests the Spotlight indexer's persisted-state codec (issue #36): the
//  watermark + id->fingerprint map round-trips byte-stably through the Core
//  Spotlight client-state blob, and an empty / legacy-bare-watermark / truncated
//  blob decodes to nil so the indexer degrades to a from-scratch reindex.
//
//  Created by Jake on 06/24/26.
//  Copyright © 2026 WXYC. All rights reserved.
//

import Foundation
import Testing
@testable import WXYCAPI

@Suite("CatalogIndexState")
struct CatalogIndexStateTests {
    static func roundTrip(_ state: CatalogIndexState) throws -> CatalogIndexState {
        try #require(CatalogIndexState(decoding: state.encode()))
    }

    @Test func roundTripsWatermarkAndMap() async throws {
        let state = CatalogIndexState(
            watermark: "Tue, 02 Jun 2026 09:30:00 GMT",
            fingerprints: [100: 0xDEAD_BEEF_CAFE_F00D, 200: 0x0000_0000_0000_0001, 7: .max]
        )
        #expect(try Self.roundTrip(state) == state)
    }

    @Test func roundTripsNilWatermark() async throws {
        let state = CatalogIndexState(watermark: nil, fingerprints: [1: 42])
        let decoded = try Self.roundTrip(state)
        #expect(decoded.watermark == nil)
        #expect(decoded.fingerprints == [1: 42])
    }

    @Test func roundTripsEmptyMap() async throws {
        let state = CatalogIndexState(watermark: "W", fingerprints: [:])
        let decoded = try Self.roundTrip(state)
        #expect(decoded.watermark == "W")
        #expect(decoded.fingerprints.isEmpty)
    }

    @Test func emptyStateRoundTrips() async throws {
        #expect(try Self.roundTrip(.empty) == .empty)
    }

    @Test func distinguishesNilWatermarkFromEmptyString() async throws {
        let nilWatermark = CatalogIndexState(watermark: nil, fingerprints: [:])
        let emptyWatermark = CatalogIndexState(watermark: "", fingerprints: [:])
        #expect(nilWatermark.encode() != emptyWatermark.encode())
        #expect(try Self.roundTrip(emptyWatermark).watermark == "")
        #expect(try Self.roundTrip(nilWatermark).watermark == nil)
    }

    @Test func encodingIsDeterministicRegardlessOfInsertionOrder() async throws {
        // The crash-recovery "re-derive the identical work set" reasoning leans on
        // equal states encoding byte-identically (entries emitted in id order).
        let a = CatalogIndexState(watermark: "W", fingerprints: [3: 30, 1: 10, 2: 20])
        var reversed: [Int: UInt64] = [:]
        for id in [2, 1, 3] { reversed[id] = UInt64(id * 10) }
        let b = CatalogIndexState(watermark: "W", fingerprints: reversed)
        #expect(a.encode() == b.encode())
    }

    @Test func roundTripsAUnicodeWatermarkAndManyEntries() async throws {
        // A non-ASCII watermark exercises the UTF8 length prefix; a few hundred
        // entries exercises the count + entry loop.
        var fingerprints: [Int: UInt64] = [:]
        for id in 1...500 { fingerprints[id] = UInt64(id) &* 0x9E37_79B9_7F4A_7C15 }
        let state = CatalogIndexState(watermark: "Nilüfer — 02 Jun 2026", fingerprints: fingerprints)
        #expect(try Self.roundTrip(state) == state)
    }

    // MARK: Defensive decode

    @Test func decodingEmptyDataReturnsNil() async throws {
        #expect(CatalogIndexState(decoding: Data()) == nil)
    }

    @Test func decodingLegacyBareWatermarkReturnsNil() async throws {
        // Issue #19 committed `Data(watermark.utf8)` — a bare string. Its first
        // byte is an ASCII char, never the format version (1), so it must be
        // rejected (-> the indexer treats it as empty and rebuilds), not misparsed.
        let legacy = Data("Mon, 01 Jun 2026 12:00:00 GMT".utf8)
        #expect(CatalogIndexState(decoding: legacy) == nil)
    }

    @Test func decodingTruncatedBlobReturnsNil() async throws {
        let full = CatalogIndexState(watermark: "W", fingerprints: [1: 1, 2: 2, 3: 3]).encode()
        // Lop off the last entry's bytes — the entry loop runs out of input.
        let truncated = full.prefix(full.count - 4)
        #expect(CatalogIndexState(decoding: Data(truncated)) == nil)
    }

    @Test func decodingWrongVersionByteReturnsNil() async throws {
        var blob = CatalogIndexState(watermark: "W", fingerprints: [1: 1]).encode()
        blob[blob.startIndex] = 0xFF   // clobber the version byte
        #expect(CatalogIndexState(decoding: blob) == nil)
    }

    @Test func decodingAnOversizedEntryCountReturnsNil() async throws {
        // A count larger than the remaining bytes can hold must be rejected. This
        // pins the observable contract (corrupt blob → nil). It does NOT, on its
        // own, prove the *no-OOM* property: the bounds guard exists so the decoder
        // returns nil BEFORE `reserveCapacity(Int(count))` requests a multi-GB
        // dictionary (which would trap on a memory-constrained device) — but the
        // host overcommits, so guard-present and guard-absent both end at nil here.
        // The guard's intent is documented at its source for future editors.
        // version=1, watermark presence=0 (nil), count=0xFFFFFFFF, no entry bytes.
        let blob = Data([0x01, 0x00, 0xFF, 0xFF, 0xFF, 0xFF])
        #expect(CatalogIndexState(decoding: blob) == nil)
    }

    // MARK: Watermark-only fast path

    @Test func decodeWatermarkReadsHeaderWithoutTheMap() async throws {
        let state = CatalogIndexState(watermark: "Tue, 02 Jun 2026 09:30:00 GMT", fingerprints: [1: 1, 2: 2, 3: 3])
        #expect(CatalogIndexState.decodeWatermark(from: state.encode()) == "Tue, 02 Jun 2026 09:30:00 GMT")
        // nil watermark, empty-string watermark, malformed, and legacy all read as
        // the same nil/"" the full decode would yield for the watermark.
        #expect(CatalogIndexState.decodeWatermark(from: CatalogIndexState(watermark: nil, fingerprints: [1: 1]).encode()) == nil)
        #expect(CatalogIndexState.decodeWatermark(from: CatalogIndexState(watermark: "", fingerprints: [:]).encode()) == "")
        #expect(CatalogIndexState.decodeWatermark(from: Data("Mon, 01 Jun 2026 12:00:00 GMT".utf8)) == nil)
        #expect(CatalogIndexState.decodeWatermark(from: Data()) == nil)
    }

    @Test func decodeWatermarkAgreesWithFullDecode() async throws {
        let state = CatalogIndexState(watermark: "W", fingerprints: [10: 100, 20: 200])
        let data = state.encode()
        #expect(CatalogIndexState.decodeWatermark(from: data) == CatalogIndexState(decoding: data)?.watermark)
    }

    @Test func decodeWatermarkSkipsTheEntryTable() async throws {
        // Prove the fast path reads ONLY the prefix, never the (~1 MB) map: a blob
        // with a valid version + watermark but a truncated entry table yields the
        // watermark from decodeWatermark while the full init(decoding:) — which
        // validates every entry — rejects it. If decodeWatermark were ever rerouted
        // through the full decode (the perf regression its doc warns against), it
        // would return nil here and this test would fail.
        let full = CatalogIndexState(watermark: "W", fingerprints: [1: 1, 2: 2]).encode()
        let entriesTruncated = Data(full.prefix(full.count - 4))   // lop the last entry's bytes
        #expect(CatalogIndexState(decoding: entriesTruncated) == nil)            // full decode rejects
        #expect(CatalogIndexState.decodeWatermark(from: entriesTruncated) == "W") // fast path still reads it
    }
}
