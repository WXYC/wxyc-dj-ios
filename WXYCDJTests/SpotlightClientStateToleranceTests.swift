//
//  SpotlightClientStateToleranceTests.swift
//  WXYCDJTests
//
//  Device-gated probe (issue #36): does Core Spotlight durably accept the ~1 MB
//  CatalogIndexState client-state blob at full-catalog scale? Round-trips an
//  encoded id->fingerprint map of increasing size through a real CSSearchableIndex
//  and asserts it reads back byte-intact — a ceiling sweep to find where
//  endBatch(withClientState:)/fetchLastClientState start failing. Skipped in CI:
//  the project's note is that simulator Spotlight is unreliable, so set
//  WXYC_SPOTLIGHT_TOLERANCE=1 and run against a PHYSICAL DEVICE destination.
//
//  Created by Jake on 06/24/26.
//  Copyright © 2026 WXYC. All rights reserved.
//

import CoreSpotlight
import Foundation
import Testing
@testable import WXYCAPI

/// Probes Core Spotlight's tolerance for the catalog's client-state blob. Gated
/// off by default — only runs when `WXYC_SPOTLIGHT_TOLERANCE` is set in the test
/// process's environment — so the CI simulator run (where Spotlight is flaky)
/// never depends on real-daemon behavior, while a maintainer can opt in on device.
/// `.serialized` because the Spotlight daemon is a shared, stateful resource and a
/// diagnostic shouldn't have several ~1 MB writes racing it at once.
@Suite(
    "Spotlight client-state tolerance",
    .serialized,
    .enabled(
        if: ProcessInfo.processInfo.environment["WXYC_SPOTLIGHT_TOLERANCE"] != nil,
        "Set WXYC_SPOTLIGHT_TOLERANCE=1 and run on a physical device; skipped in CI (simulator Spotlight is unreliable)."
    )
)
struct SpotlightClientStateToleranceTests {
    /// A `CatalogIndexState` with `rowCount` synthetic `id -> fingerprint` entries
    /// plus a realistic watermark — the exact shape `SpotlightCatalogIndexer`
    /// commits, sized to match a real catalog (~64k rows ≈ 1 MB at 16 bytes/entry).
    static func syntheticState(rowCount: Int) -> CatalogIndexState {
        var fingerprints: [Int: UInt64] = [:]
        fingerprints.reserveCapacity(rowCount)
        for id in 1...rowCount {
            fingerprints[id] = UInt64(id) &* 0x9E37_79B9_7F4A_7C15
        }
        return CatalogIndexState(watermark: "Tue, 02 Jun 2026 09:30:00 GMT", fingerprints: fingerprints)
    }

    /// Ceiling sweep: round-trip a client-state blob of increasing size through a
    /// real `CSSearchableIndex`. 64k ≈ the live catalog; 128k (≈ 2 MB) probes
    /// headroom. A case that throws at `endBatch` (rejected/too large) or whose
    /// `fetchLastClientState` returns `nil`/truncated marks the ceiling — the
    /// largest passing case is the safe size for the design.
    ///
    /// Each case uses a distinct, throwaway index name (so cases can't contaminate
    /// each other or the production `org.wxyc.dj.catalog` index) and resets it
    /// afterward. NOTE: this verifies in-process write + read-back only; durable
    /// persistence across a relaunch must be confirmed manually (run once, kill the
    /// app, relaunch, and check the next poll sends `If-Modified-Since` rather than
    /// re-indexing) — a single in-process test can't restart the daemon.
    @Test(arguments: [1_000, 10_000, 50_000, 64_000, 128_000])
    func clientStateRoundTripsAtSize(rowCount: Int) async throws {
        let blob = Self.syntheticState(rowCount: rowCount).encode()

        let rawIndex = CSSearchableIndex(name: "org.wxyc.dj.catalog.toleranceprobe.\(rowCount)")
        let index = RealSearchableIndex(rawIndex)

        index.beginBatch()
        // A throw here is the write-side ceiling (e.g. CSIndexError for an
        // over-large client state). The error is surfaced as the test failure.
        try await index.endBatch(clientState: blob)

        // A nil/short read is the read-side ceiling: the daemon accepted the write
        // but couldn't return it intact.
        let readBack = try #require(
            try await index.lastClientState(),
            "fetchLastClientState returned nil for a \(blob.count)-byte blob (\(rowCount) rows)"
        )
        #expect(
            readBack == blob,
            "client state did not round-trip intact at \(rowCount) rows (\(blob.count) bytes)"
        )
        #expect(CatalogIndexState(decoding: readBack)?.fingerprints.count == rowCount)

        // Best-effort teardown so the probe leaves no synthetic state behind.
        try? await rawIndex.deleteAllSearchableItems()
    }
}
