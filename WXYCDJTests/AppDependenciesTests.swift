//
//  AppDependenciesTests.swift
//  WXYCDJTests
//
//  Pins AppDependencies.resolveConfiguration's five branches: both keys
//  unset returns .production; either key missing returns .production
//  (the partial-config guard); unparseable URLs return .production; and
//  two valid URLs return a custom configuration. Documents the Info.plist
//  override contract so a future refactor can't silently send local-dev
//  traffic to api.wxyc.org.
//
//  Created by Jake on 5/20/26.
//  Copyright © 2026 WXYC. All rights reserved.
//

import Foundation
import Testing
import WXYCAPI
@testable import WXYCDJ

@Suite("AppDependencies.resolveConfiguration")
@MainActor
struct AppDependenciesTests {
    @Test func bothNilReturnsProduction() {
        let config = AppDependencies.resolveConfiguration(authString: nil, apiString: nil)

        #expect(config.authBaseURL == WXYCAPIConfiguration.production.authBaseURL)
        #expect(config.apiBaseURL == WXYCAPIConfiguration.production.apiBaseURL)
    }

    @Test func authStringMissingReturnsProduction() {
        let config = AppDependencies.resolveConfiguration(
            authString: nil,
            apiString: "http://localhost:8080"
        )

        #expect(config.authBaseURL == WXYCAPIConfiguration.production.authBaseURL)
        #expect(config.apiBaseURL == WXYCAPIConfiguration.production.apiBaseURL)
    }

    @Test func apiStringMissingReturnsProduction() {
        let config = AppDependencies.resolveConfiguration(
            authString: "http://localhost:8082/auth",
            apiString: nil
        )

        #expect(config.authBaseURL == WXYCAPIConfiguration.production.authBaseURL)
        #expect(config.apiBaseURL == WXYCAPIConfiguration.production.apiBaseURL)
    }

    @Test func unparseableURLReturnsProduction() {
        // Unterminated IPv6 bracket — fails URL(string:) reliably across
        // Foundation's permissive and strict parsers. Empty strings or
        // generic gibberish don't, since iOS 17+ URL is lenient about
        // both.
        let config = AppDependencies.resolveConfiguration(
            authString: "http://[::1",
            apiString: "http://[::1"
        )

        #expect(config.authBaseURL == WXYCAPIConfiguration.production.authBaseURL)
        #expect(config.apiBaseURL == WXYCAPIConfiguration.production.apiBaseURL)
    }

    @Test func bothValidReturnsCustomConfiguration() throws {
        let config = AppDependencies.resolveConfiguration(
            authString: "http://localhost:8082/auth",
            apiString: "http://localhost:8080"
        )

        #expect(config.authBaseURL.absoluteString == "http://localhost:8082/auth")
        #expect(config.apiBaseURL.absoluteString == "http://localhost:8080")
    }
}

/// The catalog clone / Spotlight refresh wiring (issue #19 step 5): where the
/// SQLite clone lives, that an openable store wires a refresh service, and that
/// a failure to locate the store degrades to inert catalog features rather than
/// crashing the composition root.
@Suite("AppDependencies.catalogWiring")
@MainActor
struct AppDependenciesCatalogWiringTests {
    @Test func defaultStoreURLLivesUnderApplicationSupport() throws {
        let appSupport = try FileManager.default.url(
            for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true
        )
        let url = try #require(AppDependencies.defaultCatalogStoreURL())

        #expect(url.lastPathComponent == "catalog.sqlite")
        #expect(url.pathComponents.contains("Catalog"))
        // Under Application Support (regenerable app-managed data, not user Documents).
        #expect(url.path(percentEncoded: false).hasPrefix(appSupport.path(percentEncoded: false)))
    }

    @Test func openableStoreWiresStoreAndRefreshService() throws {
        let url = FileManager.default.temporaryDirectory
            .appending(path: "deps-wiring-\(UUID().uuidString).sqlite")
        defer {
            let base = url.path(percentEncoded: false)
            try? FileManager.default.removeItem(at: url)
            for suffix in ["-journal", "-wal", "-shm"] {
                try? FileManager.default.removeItem(at: URL(filePath: base + suffix))
            }
        }

        let deps = AppDependencies(catalogStoreURL: url)

        #expect(deps.catalogStore != nil)
        #expect(deps.catalogRefreshService != nil)
    }

    @Test func nilStoreURLLeavesCatalogFeaturesInert() {
        // No path to open -> the catalog clone and its refresh service stay nil,
        // and the app falls back to in-app-only search instead of crashing.
        let deps = AppDependencies(catalogStoreURL: nil)

        #expect(deps.catalogStore == nil)
        #expect(deps.catalogRefreshService == nil)
    }
}

/// `catalogErrorDetail` is the verbose error formatter the catalog-refresh
/// failure log uses instead of `localizedDescription`, so a Core Spotlight
/// rejection names its domain + numeric code (e.g. `CSIndexErrorDomain -1001`
/// `InvalidItemError`) and any nested cause rather than collapsing to the opaque
/// "operation couldn't be completed".
@Suite("AppDependencies.catalogErrorDetail")
struct CatalogErrorDetailTests {
    @Test func includesDomainAndNumericCode() {
        // Mirrors the real failure we debugged: CSIndexErrorDomain -1001.
        let error = NSError(domain: "CSIndexErrorDomain", code: -1001)

        let detail = catalogErrorDetail(error)

        #expect(detail.contains("CSIndexErrorDomain"))
        #expect(detail.contains("code=-1001"))
    }

    @Test func surfacesUnderlyingErrors() {
        let underlying = NSError(domain: "LowLevelDomain", code: 42)
        let error = NSError(
            domain: "CSIndexErrorDomain",
            code: -1001,
            userInfo: [NSMultipleUnderlyingErrorsKey: [underlying]]
        )

        let detail = catalogErrorDetail(error)

        #expect(detail.contains("underlying"))
        #expect(detail.contains("LowLevelDomain"))
        #expect(detail.contains("code=42"))
    }
}
