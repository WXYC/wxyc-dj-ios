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
