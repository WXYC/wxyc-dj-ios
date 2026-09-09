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

    /// Issue #106: a genuine open failure (not merely a `nil` URL) is a silent
    /// field defect — the DJ just loses catalog features with nothing on
    /// screen to say why — so it's reported. `sqlite3_open_v2` can't create a
    /// file inside a parent directory that doesn't exist, which reliably
    /// exercises `SQLiteCatalogStore.init`'s `catch` arm without needing to
    /// simulate a real unwritable device.
    @Test func storeOpenFailureReportsAndDegrades() {
        let spy = SpyErrorReporter()
        let badURL = FileManager.default.temporaryDirectory
            .appending(path: "nonexistent-\(UUID().uuidString)/catalog.sqlite")

        let deps = AppDependencies(catalogStoreURL: badURL, reporter: spy)

        #expect(deps.catalogStore == nil)
        #expect(deps.catalogRefreshService == nil)
        #expect(spy.reportCount == 1)
        #expect(spy.reports.first?.context == "AppDependencies.init.catalogStore")
    }
}

/// The bin snapshot wiring (issue #60): where the bin SQLite store lives (its own
/// directory + DB, separate from the catalog), that an openable URL wires a store,
/// and that a nil URL degrades the bin to online-only rather than crashing.
@Suite("AppDependencies.binWiring")
@MainActor
struct AppDependenciesBinWiringTests {
    @Test func defaultBinStoreURLLivesUnderApplicationSupportInItsOwnDirectory() throws {
        let url = try #require(AppDependencies.defaultBinStoreURL())

        #expect(url.lastPathComponent == "bin.sqlite")
        // Its own "Bin" directory — deliberately not under "Catalog".
        #expect(url.pathComponents.contains("Bin"))
        #expect(!url.pathComponents.contains("Catalog"))
    }

    @Test func openableBinURLWiresStoreIndependentOfCatalog() throws {
        let url = FileManager.default.temporaryDirectory
            .appending(path: "bin-deps-wiring-\(UUID().uuidString).sqlite")
        defer {
            let base = url.path(percentEncoded: false)
            try? FileManager.default.removeItem(at: url)
            for suffix in ["-journal", "-wal", "-shm"] {
                try? FileManager.default.removeItem(at: URL(filePath: base + suffix))
            }
        }

        // No catalog store, but an openable bin URL -> the bin store is wired
        // independently of the catalog clone.
        let deps = AppDependencies(catalogStoreURL: nil, binStoreURL: url)

        #expect(deps.catalogStore == nil)
        #expect(deps.binStore != nil)
    }

    @Test func nilBinURLLeavesBinOnlineOnly() {
        let deps = AppDependencies(catalogStoreURL: nil, binStoreURL: nil)

        #expect(deps.binStore == nil)
    }

    /// The bin-store mirror of `storeOpenFailureReportsAndDegrades` above
    /// (issue #106): the DJ just sees an online-only bin, so this is the only
    /// way the failure is ever visible.
    @Test func binStoreOpenFailureReportsAndDegrades() {
        let spy = SpyErrorReporter()
        let badURL = FileManager.default.temporaryDirectory
            .appending(path: "nonexistent-\(UUID().uuidString)/bin.sqlite")

        let deps = AppDependencies(catalogStoreURL: nil, binStoreURL: badURL, reporter: spy)

        #expect(deps.binStore == nil)
        #expect(spy.reportCount == 1)
        #expect(spy.reports.first?.context == "AppDependencies.openBinStore")
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

        let detail = AppDependencies.catalogErrorDetail(error)

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

        let detail = AppDependencies.catalogErrorDetail(error)

        #expect(detail.contains("underlying"))
        #expect(detail.contains("LowLevelDomain"))
        #expect(detail.contains("code=42"))
    }
}

// MARK: - Issue #106: refreshCatalog() / handleBackgroundPoll() capture sites

/// A `CatalogStore` that answers every query with nothing. `refreshCatalog()`'s
/// and `handleBackgroundPoll()`'s error/`.notSignedIn` arms below are exercised
/// entirely by the `CatalogRefreshService`'s network leg failing (or being
/// skipped), never by store reads/writes — this exists only to satisfy the
/// initializer, on both `AppDependencies` and `CatalogRefreshService`.
private actor NullCatalogStore: CatalogStore {
    func row(id: Int) async throws -> CatalogRow? { nil }
    func count() async throws -> Int { 0 }
    func lastModified() async throws -> String? { nil }
    func replace(rows: [CatalogRow], lastModified: String?) async throws {}
    func search(query: String, limit: Int) async throws -> [CatalogRow] { [] }
}

/// A `CatalogIndexing` conformer that's never actually reached in these tests
/// (the network leg fails, or is skipped for `.notSignedIn`, before `refresh()`
/// gets to reindexing) but has to exist to satisfy `CatalogRefreshService`'s
/// `makeIndexer` factory.
private actor NullCatalogIndexer: CatalogIndexing {
    func indexedWatermark() async throws -> String? { nil }
    func reindex(snapshot: [CatalogRow], watermark: String?) async throws -> ReindexSummary {
        ReindexSummary(upserted: 0, removed: 0)
    }
    func upsert(row: CatalogRow, thumbnailData: Data?) async throws {}
}

/// Pins the issue-#106 capture sites in `AppDependencies.refreshCatalog()` and
/// `.handleBackgroundPoll()`: a genuine failure (here, a `500` from
/// `GET /library/catalog`) reports; the `APIError.notSignedIn` skip — an
/// expected state (a missing/expired session), not a defect — never does.
/// Mirrors `CatalogRefreshServiceTests.refreshAndPollWithNoSessionThrowNotSignedInAndTouchNothing`'s
/// no-session setup for the skip case.
@Suite("AppDependencies.refreshCatalog/handleBackgroundPoll reporting", .serialized)
@MainActor
struct RefreshCatalogReportingTests {
    private static let config = WXYCAPIConfiguration.localDevelopment

    /// Build a `CatalogRefreshService` whose network leg either fails (a
    /// signed-in client queued with a `500`) or throws `.notSignedIn` (no
    /// stored session, so `currentJWT()` fails before any request is sent).
    private static func makeService(signedIn: Bool) async throws -> CatalogRefreshService {
        let session = StubRequestSession()
        let storage = InMemoryTokenStorage()
        let auth: AuthService
        if signedIn {
            try storage.save("session-abc", for: .sessionToken)
            auth = AuthService(configuration: config, storage: storage, session: session)
            session.enqueue(StubRequestSession.Stub(
                statusCode: 200,
                body: Data(#"{"token":"\#(Fixtures.jwt())"}"#.utf8)
            ))
            await auth.restoreSession()
            session.enqueue(StubRequestSession.Stub(statusCode: 500, body: Data(#"{"error":"boom"}"#.utf8)))
        } else {
            auth = AuthService(configuration: config, storage: storage, session: session)
            await auth.restoreSession()   // no token -> .signedOut
        }
        let client = APIClient(configuration: config, session: session, authService: auth)
        return CatalogRefreshService(client: client, store: NullCatalogStore(), makeIndexer: { NullCatalogIndexer() })
    }

    @Test func genuineRefreshFailureReports() async throws {
        let spy = SpyErrorReporter()
        let service = try await Self.makeService(signedIn: true)
        let deps = AppDependencies(catalogStore: NullCatalogStore(), catalogRefreshService: service, reporter: spy)

        let success = await deps.refreshCatalog(trigger: .launch)

        #expect(success == false)
        #expect(spy.reportCount == 1)
        #expect(spy.reports.first?.context == "AppDependencies.refreshCatalog")
    }

    @Test func notSignedInSkipDuringRefreshDoesNotReport() async throws {
        let spy = SpyErrorReporter()
        let service = try await Self.makeService(signedIn: false)
        let deps = AppDependencies(catalogStore: NullCatalogStore(), catalogRefreshService: service, reporter: spy)

        let success = await deps.refreshCatalog(trigger: .launch)

        #expect(success == true)
        #expect(spy.reportCount == 0)
    }

    @Test func genuineBackgroundPollFailureReports() async throws {
        let spy = SpyErrorReporter()
        let service = try await Self.makeService(signedIn: true)
        let deps = AppDependencies(catalogStore: NullCatalogStore(), catalogRefreshService: service, reporter: spy)

        await deps.handleBackgroundPoll()

        #expect(spy.reportCount == 1)
        #expect(spy.reports.first?.context == "AppDependencies.handleBackgroundPoll")
    }

    @Test func notSignedInSkipDuringBackgroundPollDoesNotReport() async throws {
        let spy = SpyErrorReporter()
        let service = try await Self.makeService(signedIn: false)
        let deps = AppDependencies(catalogStore: NullCatalogStore(), catalogRefreshService: service, reporter: spy)

        await deps.handleBackgroundPoll()

        #expect(spy.reportCount == 0)
    }

    /// Issue #106 review Fix 1: being offline is a supported mode, not a
    /// defect — an offline DJ must not generate a Sentry event on every
    /// launch/scene-`.active` refresh. A signed-in client whose transport
    /// throws a connectivity-class `URLError` is the shape `APIClient.fire(_:)`
    /// now classifies as `.offline` rather than `.network`.
    private static func makeOfflineService() async throws -> CatalogRefreshService {
        let session = StubRequestSession()
        let storage = InMemoryTokenStorage()
        try storage.save("session-abc", for: .sessionToken)
        let auth = AuthService(configuration: config, storage: storage, session: session)
        session.enqueue(StubRequestSession.Stub(
            statusCode: 200,
            body: Data(#"{"token":"\#(Fixtures.jwt())"}"#.utf8)
        ))
        await auth.restoreSession()
        session.enqueue(failure: URLError(.notConnectedToInternet))
        let client = APIClient(configuration: config, session: session, authService: auth)
        return CatalogRefreshService(client: client, store: NullCatalogStore(), makeIndexer: { NullCatalogIndexer() })
    }

    @Test func offlineFailureDuringRefreshDoesNotReport() async throws {
        let spy = SpyErrorReporter()
        let service = try await Self.makeOfflineService()
        let deps = AppDependencies(catalogStore: NullCatalogStore(), catalogRefreshService: service, reporter: spy)

        let success = await deps.refreshCatalog(trigger: .launch)

        #expect(success == false)
        #expect(spy.reportCount == 0)
    }

    @Test func offlineFailureDuringBackgroundPollDoesNotReport() async throws {
        let spy = SpyErrorReporter()
        let service = try await Self.makeOfflineService()
        let deps = AppDependencies(catalogStore: NullCatalogStore(), catalogRefreshService: service, reporter: spy)

        await deps.handleBackgroundPoll()

        #expect(spy.reportCount == 0)
    }

    // MARK: - Issue #108: catalog_refresh_completed analytics

    @Test func genuineRefreshFailureRecordsAFailedOutcomeWithTheCallerSTrigger() async throws {
        let service = try await Self.makeService(signedIn: true)
        let analytics = SpyAnalytics()
        let deps = AppDependencies(catalogStore: NullCatalogStore(), catalogRefreshService: service, analytics: analytics)

        _ = await deps.refreshCatalog(trigger: .background)

        #expect(analytics.captures.count == 1)
        let capture = try #require(analytics.captures.first)
        #expect(capture.name == "catalog_refresh_completed")
        #expect(capture.properties["outcome"] == .enumString(CatalogRefreshOutcome.failed))
        #expect(capture.properties["trigger"] == .enumString(CatalogRefreshTrigger.background))
        #expect(capture.properties["row_count"] == .int(0))
    }

    /// A missing/expired session isn't a refresh attempt at all (issue #106's
    /// identical carve-out for error reporting) -- nothing to log.
    @Test func notSignedInSkipDuringRefreshRecordsNoAnalyticsEvent() async throws {
        let service = try await Self.makeService(signedIn: false)
        let analytics = SpyAnalytics()
        let deps = AppDependencies(catalogStore: NullCatalogStore(), catalogRefreshService: service, analytics: analytics)

        _ = await deps.refreshCatalog(trigger: .launch)

        #expect(analytics.captures.isEmpty)
    }

    /// Being offline is a supported mode, never worth a Sentry event (issue
    /// #106 review Fix 1) -- but it *is* a genuine refresh attempt worth
    /// counting as `.failed` for product analytics (issue #108): station
    /// network health is exactly what `catalog_refresh_completed`'s
    /// `outcome` and the connectivity events both exist to answer.
    @Test func offlineFailureDuringRefreshRecordsAFailedOutcome() async throws {
        let service = try await Self.makeOfflineService()
        let analytics = SpyAnalytics()
        let deps = AppDependencies(catalogStore: NullCatalogStore(), catalogRefreshService: service, analytics: analytics)

        _ = await deps.refreshCatalog(trigger: .foreground)

        #expect(analytics.captures.count == 1)
        let capture = try #require(analytics.captures.first)
        #expect(capture.properties["outcome"] == .enumString(CatalogRefreshOutcome.failed))
        #expect(capture.properties["trigger"] == .enumString(CatalogRefreshTrigger.foreground))
    }

    /// Issue #118 "also worth a sentence": before this, a `refreshCatalog()`
    /// call with no `catalogRefreshService` at all (the SQLite store never
    /// opened) recorded nothing, so a device with a permanently broken store
    /// was invisible in this metric -- indistinguishable from one that simply
    /// never refreshed.
    @Test func refreshWithNoCatalogRefreshServiceRecordsNoStoreOutcome() async throws {
        let analytics = SpyAnalytics()
        let deps = AppDependencies(catalogStoreURL: nil, analytics: analytics)

        let success = await deps.refreshCatalog(trigger: .launch)

        #expect(success == true)
        #expect(analytics.captures.count == 1)
        let capture = try #require(analytics.captures.first)
        #expect(capture.name == "catalog_refresh_completed")
        #expect(capture.properties["outcome"] == .enumString(CatalogRefreshOutcome.noStore))
        #expect(capture.properties["trigger"] == .enumString(CatalogRefreshTrigger.launch))
    }

    // MARK: - Issue #118 item 3: handleBackgroundPoll() analytics

    /// Build a signed-in `CatalogRefreshService` whose one queued network leg
    /// answers with `stub`, parameterized on the response so the poll-specific
    /// tests (a `200` with a body, a bare `304`) don't have to repeat it.
    ///
    /// Delegates the sign-in/JWT bootstrap to `SignedInClient.make()`, the
    /// shared `Support/` fixture built for exactly this, rather than re-pasting
    /// it: two co-located helpers in this file already inline that sequence, and
    /// a third copy would be a third place to fix when the JWT fixture shape
    /// moves. `SignedInClient.configuration` is `.localDevelopment`, the same
    /// value `config` holds here, so this is behaviour-preserving.
    private static func makeSignedInService(queuing stub: StubRequestSession.Stub) async throws -> CatalogRefreshService {
        let (client, session) = try await SignedInClient.make()
        session.enqueue(stub)
        return CatalogRefreshService(client: client, store: NullCatalogStore(), makeIndexer: { NullCatalogIndexer() })
    }

    /// The poll leg's core fix: before issue #118, `handleBackgroundPoll()`
    /// recorded nothing at all, so a `BGAppRefreshTask` that ran faithfully
    /// but found no change (or ran on a device that's never on a charger, so
    /// the reindex `BGProcessingTask` never followed up) was indistinguishable
    /// from "background tasks never fire."
    @Test func pollDetectingAChangeRecordsPollChangedWithBackgroundPollTrigger() async throws {
        let service = try await Self.makeSignedInService(queuing: StubRequestSession.Stub(
            statusCode: 200, headers: ["Last-Modified": "NEW"], body: Data(Fixtures.catalogNDJSON.utf8)
        ))
        let analytics = SpyAnalytics()
        let deps = AppDependencies(catalogStore: NullCatalogStore(), catalogRefreshService: service, analytics: analytics)

        await deps.handleBackgroundPoll()

        #expect(analytics.captures.count == 1)
        let capture = try #require(analytics.captures.first)
        #expect(capture.name == "catalog_refresh_completed")
        #expect(capture.properties["outcome"] == .enumString(CatalogRefreshOutcome.pollChanged))
        #expect(capture.properties["trigger"] == .enumString(CatalogRefreshTrigger.backgroundPoll))
    }

    @Test func pollFindingNoChangeRecordsUpToDateWithBackgroundPollTrigger() async throws {
        let service = try await Self.makeSignedInService(queuing: StubRequestSession.Stub(statusCode: 304))
        let analytics = SpyAnalytics()
        let deps = AppDependencies(catalogStore: NullCatalogStore(), catalogRefreshService: service, analytics: analytics)

        await deps.handleBackgroundPoll()

        #expect(analytics.captures.count == 1)
        let capture = try #require(analytics.captures.first)
        #expect(capture.properties["outcome"] == .enumString(CatalogRefreshOutcome.upToDate))
        #expect(capture.properties["trigger"] == .enumString(CatalogRefreshTrigger.backgroundPoll))
    }

    @Test func genuineBackgroundPollFailureRecordsAFailedOutcomeWithBackgroundPollTrigger() async throws {
        let service = try await Self.makeService(signedIn: true)
        let analytics = SpyAnalytics()
        let deps = AppDependencies(catalogStore: NullCatalogStore(), catalogRefreshService: service, analytics: analytics)

        await deps.handleBackgroundPoll()

        #expect(analytics.captures.count == 1)
        let capture = try #require(analytics.captures.first)
        #expect(capture.properties["outcome"] == .enumString(CatalogRefreshOutcome.failed))
        #expect(capture.properties["trigger"] == .enumString(CatalogRefreshTrigger.backgroundPoll))
    }

    /// Offline is never worth a Sentry event, but it's still a genuine
    /// attempt worth counting for product analytics (mirrors
    /// `offlineFailureDuringRefreshRecordsAFailedOutcome` above).
    @Test func offlineDuringBackgroundPollRecordsAFailedOutcomeWithBackgroundPollTrigger() async throws {
        let service = try await Self.makeOfflineService()
        let analytics = SpyAnalytics()
        let deps = AppDependencies(catalogStore: NullCatalogStore(), catalogRefreshService: service, analytics: analytics)

        await deps.handleBackgroundPoll()

        #expect(analytics.captures.count == 1)
        let capture = try #require(analytics.captures.first)
        #expect(capture.properties["outcome"] == .enumString(CatalogRefreshOutcome.failed))
        #expect(capture.properties["trigger"] == .enumString(CatalogRefreshTrigger.backgroundPoll))
    }

    /// A missing/expired session isn't a poll attempt at all -- identical
    /// carve-out to `notSignedInSkipDuringRefreshRecordsNoAnalyticsEvent`.
    @Test func notSignedInSkipDuringBackgroundPollRecordsNoAnalyticsEvent() async throws {
        let service = try await Self.makeService(signedIn: false)
        let analytics = SpyAnalytics()
        let deps = AppDependencies(catalogStore: NullCatalogStore(), catalogRefreshService: service, analytics: analytics)

        await deps.handleBackgroundPoll()

        #expect(analytics.captures.isEmpty)
    }

    /// Issue #118 review: the no-store degrade is recorded on the poll leg
    /// too, not only in `refreshCatalog()`. Reachable even though
    /// `scheduleBackgroundRefreshIfAvailable()` checks for a store, because a
    /// task submitted on a launch that had one fires on a later launch whose
    /// store failed to open -- and closing the "broken store looks like a
    /// device that never refreshed" gap on one leg while leaving it open on
    /// the other would be the same blind spot in a different place.
    @Test func backgroundPollWithNoCatalogRefreshServiceRecordsNoStoreOutcome() async throws {
        let analytics = SpyAnalytics()
        let deps = AppDependencies(catalogStoreURL: nil, analytics: analytics)

        await deps.handleBackgroundPoll()

        #expect(analytics.captures.count == 1)
        let capture = try #require(analytics.captures.first)
        #expect(capture.name == "catalog_refresh_completed")
        #expect(capture.properties["outcome"] == .enumString(CatalogRefreshOutcome.noStore))
        #expect(capture.properties["trigger"] == .enumString(CatalogRefreshTrigger.backgroundPoll))
    }
}
