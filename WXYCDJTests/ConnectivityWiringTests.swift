//
//  ConnectivityWiringTests.swift
//  WXYCDJTests
//
//  Pins the issue-#56 app-layer wiring: AppDependencies owns a
//  ConnectivityMonitor that starts optimistically online, and the catalog
//  watermark formats into the banner's "last synced" line (falling back to the
//  raw string when unparseable).
//
//  Created by Jake on 6/26/26.
//  Copyright © 2026 WXYC. All rights reserved.
//

import Foundation
import Testing
import WXYCAPI
@testable import WXYCDJ

@Suite("AppDependencies.connectivity")
@MainActor
struct ConnectivityWiringTests {
    @Test func connectivityStartsOptimisticallyOnline() {
        let deps = AppDependencies(catalogStoreURL: nil)
        #expect(deps.connectivity.isOnline == true)
    }

    @Test func lastCatalogSyncTextStartsNil() {
        let deps = AppDependencies(catalogStoreURL: nil)
        #expect(deps.lastCatalogSyncText == nil)
    }
}

@Suite("AppDependencies.formatSyncDate")
struct FormatSyncDateTests {
    @Test func parsesRFC1123Watermark() {
        // The verbatim Last-Modified shape the catalog watermark stores.
        let formatted = AppDependencies.formatSyncDate("Wed, 24 Jun 2026 12:00:00 GMT")

        // Parsed and reformatted (no longer the raw RFC 1123 string); the year
        // survives regardless of the host locale/timezone the display uses.
        #expect(formatted != "Wed, 24 Jun 2026 12:00:00 GMT")
        #expect(formatted.contains("2026"))
    }

    @Test func fallsBackToRawStringWhenUnparseable() {
        let garbage = "not a date"
        #expect(AppDependencies.formatSyncDate(garbage) == garbage)
    }
}

/// A `CatalogStore` whose `lastModified()` returns a settable watermark or, once
/// armed, throws — so the "last synced" line's resilience to a transient
/// watermark-read failure can be driven through `refreshCatalog()`. An `actor`,
/// so it's `Sendable` and race-free.
private actor FlakyWatermarkStore: CatalogStore {
    private var watermark: String?
    private var throwOnRead = false

    init(watermark: String?) { self.watermark = watermark }

    /// Arm the next (and every subsequent) `lastModified()` to throw.
    func startThrowing() { throwOnRead = true }

    func lastModified() async throws -> String? {
        if throwOnRead { throw URLError(.cannotOpenFile) }
        return watermark
    }

    // Unused by updateLastCatalogSyncText.
    func row(id: Int) async throws -> CatalogRow? { nil }
    func count() async throws -> Int { 0 }
    func replace(rows: [CatalogRow], lastModified: String?) async throws { watermark = lastModified }
    func search(query: String, limit: Int) async throws -> [CatalogRow] { [] }
}

@Suite("AppDependencies.lastCatalogSyncText")
@MainActor
struct LastCatalogSyncTextTests {
    /// A successful watermark read formats into the banner's "last synced" line.
    @Test func goodReadPopulatesSyncText() async {
        let store = FlakyWatermarkStore(watermark: "Wed, 24 Jun 2026 12:00:00 GMT")
        let deps = AppDependencies(catalogStore: store)

        await deps.refreshCatalog(trigger: .launch)

        #expect(deps.lastCatalogSyncText?.contains("2026") == true)
    }

    /// A *transient* watermark-read failure after a good sync must NOT wipe the
    /// previously-good "last synced" line back to "Never synced" — the regression
    /// this guards against was `try?` flattening the throw to `nil` and then
    /// unconditionally overwriting the stored value.
    @Test func transientReadFailurePreservesPreviousSyncText() async {
        let store = FlakyWatermarkStore(watermark: "Wed, 24 Jun 2026 12:00:00 GMT")
        let deps = AppDependencies(catalogStore: store)

        await deps.refreshCatalog(trigger: .launch)
        let afterGoodSync = deps.lastCatalogSyncText
        #expect(afterGoodSync != nil)

        await store.startThrowing()
        await deps.refreshCatalog(trigger: .launch)

        // Preserved, not wiped to nil.
        #expect(deps.lastCatalogSyncText == afterGoodSync)
    }
}
