//
//  AppDependencies.swift
//  WXYCDJ
//
//  Single composition root for the app: picks a WXYCAPIConfiguration
//  (production by default; localhost override via Info.plist), wires the
//  AuthService and APIClient, the on-device catalog clone + Spotlight indexer +
//  shared CatalogRefreshService (issue #19), and is injected through the SwiftUI
//  environment.
//
//  Created by Jake on 5/14/26.
//  Copyright © 2026 WXYC. All rights reserved.
//

import Foundation
import Observation
import OSLog
import WXYCAPI

private let configLog = Logger(subsystem: "org.wxyc.dj", category: "config")
private let deepLinkLog = Logger(subsystem: "org.wxyc.dj", category: "deeplink")

@MainActor
@Observable
final class AppDependencies {
    let configuration: WXYCAPIConfiguration
    let authService: AuthService
    let api: APIClient
    /// Biometric authenticator used by the QR sign-in flow (ADR 0002). Built
    /// over `LAContext.evaluatePolicy(.deviceOwnerAuthentication, ...)` by
    /// default; tests inject a stub via the dedicated initializer. Holding it
    /// on the composition root keeps view models free of any
    /// LocalAuthentication import.
    let biometrics: any BiometricAuthenticator
    /// Feature gate for the QR-sign-in menu entry (ADR 0002). Reads
    /// `WXYCQRSignInEnabled` from the Info.plist (`false` until the
    /// Backend-Service `/auth/device/verify` endpoint ships); flipping the
    /// key on rebuild is the entire deployment switch.
    let qrSignInEnabled: Bool
    /// App-wide online/offline signal (issue #56), corrected by real transport
    /// outcomes from both the ``APIClient`` hook and the ``AuthService`` hook
    /// (issue #71 — so a JWT-refresh-leg failure that never reaches `APIClient`
    /// still latches offline). Started against the live `NWPathMonitor` from
    /// ``startConnectivityMonitoring()`` at launch; left unstarted (optimistically
    /// online) in unit tests.
    let connectivity: ConnectivityMonitor
    /// Human-readable "last synced" timestamp for the offline banner (issue #56),
    /// derived from the catalog watermark (``CatalogStore/lastModified()``) at the
    /// end of ``refreshCatalog()``. `nil` until the first successful clone — the
    /// banner shows a "Never synced" placeholder. Kept here (not in the banner
    /// body) so the async watermark read stays off the view.
    private(set) var lastCatalogSyncText: String?
    /// The id-keyed on-device catalog clone (issue #19). `nil` only if the
    /// SQLite store couldn't be opened (disk unwritable) — the app degrades to
    /// in-app-only search rather than crashing. The Spotlight deep-link (step 7)
    /// reads it for an O(1) id→row `fallback` lookup.
    let catalogStore: (any CatalogStore)?
    /// The per-DJ bin snapshot store (issue #60). Its **own** SQLite DB + actor,
    /// deliberately independent of ``catalogStore`` so a bin read never queues
    /// behind a multi-second catalog replace. `nil` only if the SQLite store
    /// couldn't be opened — the bin then degrades to online-only.
    let binStore: (any BinStore)?
    /// Online-first / offline-fallback library search router (issue #58). Reads
    /// ``connectivity`` to decide server-vs-local per request and searches the
    /// ``catalogStore`` FTS index when offline or when the request fails.
    /// Constructed once over the shared API client, store, and monitor; handed to
    /// each ``SearchViewModel``.
    let librarySearch: LibrarySearch
    /// The single shared refresh service the foreground path and both background
    /// tasks drive. **Exactly one instance** app-wide: its actor serializes all
    /// index touches (refreshes + the issue-#44 lazy thumbnail upserts) through one
    /// chain, which is what keeps `RealSearchableIndex`'s `@unchecked Sendable` sound
    /// (no two Spotlight batches open at once). `nil` when ``catalogStore`` is.
    let catalogRefreshService: CatalogRefreshService?
    /// Cold-launch Spotlight deep-link state (issue #19 step 7), injected via
    /// `.environment` and bound to RootView's `fullScreenCover`. The resolution
    /// that turns a tapped `album.<id>` into a route lives here — on
    /// ``handleSpotlightTap(albumID:isSignedIn:)`` /
    /// ``handleAuthChange(wasSignedIn:isSignedIn:)`` — because the `fallback`
    /// lookup needs ``catalogStore``.
    let router = Router()
    /// Monotonic generation for ``present(albumID:)``'s most-recent-wins latch,
    /// so a stale parked drain can't clobber a freshly-tapped album when their
    /// clone lookups race across the `await`.
    private var presentationToken = 0

    convenience init() {
        self.init(
            catalogStoreURL: Self.defaultCatalogStoreURL(),
            binStoreURL: Self.defaultBinStoreURL()
        )
    }

    /// Read the QR-sign-in feature gate from the bundle. Default is `false`
    /// (the v1 ship state) — a missing or non-bool value also reads as off,
    /// so an upstream typo never silently enables the feature.
    private static func resolveQRSignInEnabled() -> Bool {
        Bundle.main.object(forInfoDictionaryKey: "WXYCQRSignInEnabled") as? Bool ?? false
    }

    /// Designated initializer. `catalogStoreURL` is the SQLite clone's path and
    /// `binStoreURL` the bin snapshot's path (both injected in tests; the
    /// defaults point under Application Support). A `nil` URL, or a store that
    /// fails to open, leaves that feature inert. `binStoreURL` defaults to `nil`
    /// so existing catalog-only test call sites don't open a real bin store.
    init(
        catalogStoreURL: URL?,
        binStoreURL: URL? = nil,
        biometrics: any BiometricAuthenticator = LocalAuthenticationAuthenticator(),
        qrSignInEnabled: Bool? = nil
    ) {
        let connectivity = ConnectivityMonitor()
        self.connectivity = connectivity
        let (configuration, authService, api) = Self.makeCore(onOutcome: Self.outcomeHandler(for: connectivity))
        self.configuration = configuration
        self.authService = authService
        self.api = api
        self.biometrics = biometrics
        self.qrSignInEnabled = qrSignInEnabled ?? Self.resolveQRSignInEnabled()

        // Catalog clone + Spotlight index. Store construction can fail (disk
        // unwritable); degrade to no catalog features rather than crash. One
        // CatalogRefreshService wraps the store + a live named CSSearchableIndex.
        if let catalogStoreURL {
            do {
                let store = try SQLiteCatalogStore(url: catalogStoreURL)
                self.catalogStore = store
                // The on-device Spotlight thumbnail cache (issue #44). nil (-> no
                // artwork feature) if the cache dir can't be located; production
                // uses URLSession.shared so it reuses the AsyncImage/URLCache the
                // in-app cover loads already populated.
                let thumbnailProvider = Self.defaultThumbnailDirectoryURL().map {
                    DiskThumbnailProvider(directory: $0)
                }
                // A fresh indexer per run (CatalogRefreshService builds one from
                // this factory) so an in-process reindex retry never reuses a
                // poisoned Core Spotlight batch.
                self.catalogRefreshService = CatalogRefreshService(
                    client: api,
                    store: store,
                    makeIndexer: { SpotlightCatalogIndexer() },
                    thumbnailProvider: thumbnailProvider
                )
            } catch {
                catalogLog.error("Catalog store unavailable at \(catalogStoreURL.path, privacy: .public): \(error.localizedDescription, privacy: .public). Falling back to in-app-only search.")
                self.catalogStore = nil
                self.catalogRefreshService = nil
            }
        } else {
            self.catalogStore = nil
            self.catalogRefreshService = nil
        }

        // The bin snapshot store (issue #60). Opened independently of the catalog
        // store — its own DB + actor — so an offline bin read never waits behind a
        // catalog replace. Degrades to online-only (nil) if the file can't open.
        self.binStore = Self.openBinStore(at: binStoreURL)
        self.librarySearch = LibrarySearch(api: api, catalogStore: catalogStore, connectivity: connectivity)
    }

    /// Open the bin snapshot store at `url`, logging and degrading to `nil` on
    /// failure (disk unwritable) so the composition root never crashes.
    private static func openBinStore(at url: URL?) -> (any BinStore)? {
        guard let url else { return nil }
        do {
            return try SQLiteBinStore(url: url)
        } catch {
            catalogLog.error("Bin store unavailable at \(url.path, privacy: .public): \(error.localizedDescription, privacy: .public). Falling back to online-only bin.")
            return nil
        }
    }

    /// Test seam: build the composition root around an injected catalog store and
    /// no refresh service. The deep-link resolution path (``handleSpotlightTap``,
    /// ``handleAuthChange``, ``present(albumID:)``) reads only ``catalogStore``,
    /// so a unit test can supply a store whose `row(id:)` suspends on demand to
    /// drive `present`'s most-recent-wins token latch across the `await` —
    /// the one branch the sequential-await tests can't reach.
    init(
        catalogStore: any CatalogStore,
        biometrics: any BiometricAuthenticator = LocalAuthenticationAuthenticator(),
        qrSignInEnabled: Bool = false
    ) {
        let connectivity = ConnectivityMonitor()
        self.connectivity = connectivity
        let (configuration, authService, api) = Self.makeCore(onOutcome: Self.outcomeHandler(for: connectivity))
        self.configuration = configuration
        self.authService = authService
        self.api = api
        self.biometrics = biometrics
        self.qrSignInEnabled = qrSignInEnabled
        self.catalogStore = catalogStore
        self.catalogRefreshService = nil
        self.binStore = nil
        self.librarySearch = LibrarySearch(api: api, catalogStore: catalogStore, connectivity: connectivity)
    }

    /// Build the configuration + auth + API client shared by every initializer.
    /// `onOutcome` is the connectivity correction hook: each transport result
    /// feeds ``ConnectivityMonitor/ingest(isOnline:)``. The **same** closure is
    /// handed to both ``APIClient`` (issue #56 — data-endpoint requests) and
    /// ``AuthService`` (issue #71 — the `/auth/*` transport, incl. the JWT-refresh
    /// leg that resolves *before* `APIClient` ever calls `fire()`). Sharing one
    /// closure keeps every outcome in the monitor's single ordered `ingest` FIFO,
    /// so an auth-transport failure and a data-request outcome can't apply
    /// out-of-order and break last-write-wins.
    private static func makeCore(
        onOutcome: @escaping @Sendable (Bool) -> Void
    ) -> (WXYCAPIConfiguration, AuthService, APIClient) {
        let bundle = Bundle.main
        let configuration = resolveConfiguration(
            authString: bundle.object(forInfoDictionaryKey: "WXYCAuthBaseURL") as? String,
            apiString: bundle.object(forInfoDictionaryKey: "WXYCAPIBaseURL") as? String
        )
        let authService = AuthService(configuration: configuration, onOutcome: onOutcome)
        let api = APIClient(configuration: configuration, authService: authService, onOutcome: onOutcome)
        return (configuration, authService, api)
    }

    /// The `@Sendable` closure the WXYCAPI layer (``APIClient`` for data requests,
    /// ``AuthService`` for the `/auth/*` transport) calls with each transport
    /// result. Feeds the monitor's `nonisolated`, **ordered**
    /// ``ConnectivityMonitor/ingest(isOnline:)`` directly — no `Task { @MainActor }`
    /// wrapper, which would let two near-simultaneous outcomes (or an outcome
    /// racing a path update) apply out of submission order on the main actor and
    /// break last-write-wins. Captures the monitor (not `self`) so it can be built
    /// before the rest of the root; keeps WXYCAPI free of any MainActor coupling.
    private static func outcomeHandler(for connectivity: ConnectivityMonitor) -> @Sendable (Bool) -> Void {
        { success in connectivity.ingest(isOnline: success) }
    }

    /// Begin tracking the live network path. Called once at launch (not from the
    /// initializers) so unit tests don't spin up a real `NWPathMonitor`; until
    /// then the monitor is optimistically online and outcome-corrected only.
    func startConnectivityMonitoring() {
        connectivity.start(pathProvider: RealPathProvider())
    }

    // MARK: Catalog refresh

    /// Best-effort foreground/reindex refresh: poll → `304`/`200` → store-replace
    /// → Spotlight-reindex via the shared service. Logs the outcome. A missing or
    /// expired session (`APIError.notSignedIn`) is a **silent skip** — never an
    /// error banner, never a sign-in prompt. Called from the launch/foreground
    /// `.task`, on scene-activation, and (via the reindex BGTask) in the
    /// background.
    ///
    /// Returns whether the run was "successful" for `BGTask.setTaskCompleted`:
    /// `true` on a real refresh/304 **and** on a clean no-session skip (the task
    /// did its job; we'll retry next cycle), `false` only on a genuine error
    /// (network/decode) so iOS may reschedule sooner.
    @discardableResult
    func refreshCatalog() async -> Bool {
        guard let catalogRefreshService else {
            await updateLastCatalogSyncText()
            return true
        }
        let success: Bool
        do {
            let outcome = try await catalogRefreshService.refresh()
            catalogLog.info("Catalog refresh: \(String(describing: outcome), privacy: .public)")
            success = true
        } catch APIError.notSignedIn {
            catalogLog.debug("Catalog refresh skipped: not signed in")
            success = true
        } catch {
            catalogLog.error("Catalog refresh failed: \(Self.catalogErrorDetail(error), privacy: .public)")
            success = false
        }
        // Re-derive the "last synced" line from the clone's watermark regardless
        // of outcome (a 304 leaves it unchanged; a 200 advances it).
        await updateLastCatalogSyncText()
        return success
    }

    /// Refresh ``lastCatalogSyncText`` from the catalog watermark. A `nil` store
    /// leaves it `nil`, so the banner shows "Never synced". Parsing/formatting is
    /// the pure ``formatSyncDate(_:)``.
    ///
    /// A *successful* read of a never-populated clone returns `nil` (the store
    /// reports no watermark), which correctly shows "Never synced". A read that
    /// **throws** (a transient SQLite lock / I/O error) preserves the previous
    /// value instead of wiping it — otherwise a single flaky read after a good
    /// sync would regress a live banner to "Never synced".
    private func updateLastCatalogSyncText() async {
        guard let catalogStore else {
            lastCatalogSyncText = nil
            return
        }
        do {
            let watermark = try await catalogStore.lastModified()
            lastCatalogSyncText = watermark.map(Self.formatSyncDate)
        } catch {
            catalogLog.debug("Last-synced watermark read failed; keeping previous value: \(Self.catalogErrorDetail(error), privacy: .public)")
        }
    }

    /// Format the catalog's verbatim RFC 1123 `Last-Modified` watermark
    /// ("Wed, 24 Jun 2026 12:00:00 GMT") into a locale-aware display string for
    /// the offline banner. Falls back to the raw string if it doesn't parse, so
    /// the banner always shows something concrete. `nonisolated` + pure so it's
    /// directly unit-testable.
    nonisolated static func formatSyncDate(_ rfc1123: String) -> String {
        let parser = DateFormatter()
        parser.locale = Locale(identifier: "en_US_POSIX")
        parser.timeZone = TimeZone(identifier: "GMT")
        parser.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
        guard let date = parser.date(from: rfc1123) else { return rfc1123 }
        return date.formatted(date: .abbreviated, time: .shortened)
    }

    /// Lazily cache + attach `albumID`'s Spotlight cover thumbnail (issue #44).
    /// **Foreground / user-initiated only** — call it when the DJ views an album
    /// (``AlbumDetailView``) or a search row surfaces; never from the background
    /// poll leg, which must stay a cheap conditional probe. All the work — resolve
    /// row + fetch/downscale/cache + the per-cover dedup + non-batch upsert — lives
    /// on ``CatalogRefreshService`` (the dedup is keyed on the cover's cache file
    /// there, so a changed cover re-attaches and a reindex-stripped one self-heals;
    /// an id-keyed skip here couldn't do either).
    func cacheThumbnail(forAlbumID albumID: Int) async {
        await catalogRefreshService?.cacheThumbnail(forAlbumID: albumID)
    }

    /// The `BGAppRefreshTask` poll leg: if there's no catalog store there's
    /// nothing to poll for and re-arming would schedule wake-ups that can never
    /// progress, so bail without rescheduling. Otherwise re-arm the next poll
    /// first (so even a thrown poll or a missing session reschedules), then do the
    /// cheap conditional GET; on a `200` submit the charging-gated reindex
    /// `BGProcessingTask` rather than reindexing on the ~30 s app-refresh budget.
    /// A missing/expired session is a silent skip + reschedule.
    func handleBackgroundPoll() async {
        guard let catalogRefreshService else { return }
        CatalogBackgroundTasks.scheduleNextPoll()
        do {
            if try await catalogRefreshService.poll() {
                CatalogBackgroundTasks.scheduleReindex()
            }
        } catch APIError.notSignedIn {
            catalogLog.debug("Background catalog poll skipped: not signed in")
        } catch {
            catalogLog.error("Background catalog poll failed: \(Self.catalogErrorDetail(error), privacy: .public)")
        }
    }

    /// Arm the background app-refresh poll on scene-background — but only if
    /// there's a catalog store to refresh, so a device that couldn't open the
    /// store doesn't schedule wake-ups that structurally can't progress.
    func scheduleBackgroundRefreshIfAvailable() {
        guard catalogRefreshService != nil else { return }
        CatalogBackgroundTasks.scheduleNextPoll()
    }

    // MARK: Spotlight deep link (issue #19 step 7)

    /// Route a Core Spotlight **continuation activity** — the `NSUserActivity` of
    /// type `CSSearchableItemActionType` the system hands back when a DJ taps a
    /// catalog item in home-screen Spotlight — to the deep-link surface. Parses
    /// the `"album.<id>"` identifier and forwards to
    /// ``handleSpotlightTap(albumID:isSignedIn:)`` with the live auth state. A
    /// non-continuation or malformed activity is a no-op.
    ///
    /// This is the single entry point ``SceneDelegate`` drives for **both**
    /// cold-launch (`scene(_:willConnectTo:)`, where the launch activity arrives
    /// in `connectionOptions`) and warm (`scene(_:continue:)`) taps. The
    /// `UIWindowSceneDelegate` is the reliable delivery path: SwiftUI's view-level
    /// `onContinueUserActivity` was not firing for this activity in either state,
    /// so the tap never reached the (correct, tested) park/replay/present logic.
    func handleSpotlightContinuation(_ activity: NSUserActivity) async {
        guard let albumID = CatalogSpotlight.albumID(fromActivity: activity) else { return }
        deepLinkLog.debug("Spotlight continuation -> album \(albumID, privacy: .public) (signedIn=\(self.authService.isSignedIn, privacy: .public))")
        await handleSpotlightTap(albumID: albumID, isSignedIn: authService.isSignedIn)
    }

    /// Handle a Spotlight tap on `album.<id>`. When signed in, resolve the route
    /// (with an O(1) clone lookup for the instant-header `fallback`) and present
    /// it immediately by setting ``Router/deepLink``. Otherwise — a tap that
    /// landed while signed out or mid-`restoreSession()` — park the id in
    /// ``Router/pending`` for ``handleAuthChange(wasSignedIn:isSignedIn:)`` to
    /// replay once auth resolves. Never flips auth state or surfaces a sign-in prompt.
    ///
    /// `isSignedIn` is passed in (rather than read off ``authService``) so the
    /// replay logic is unit-testable without driving a real sign-in; the caller
    /// (RootView) supplies `authService.isSignedIn`.
    func handleSpotlightTap(albumID: Int, isSignedIn: Bool) async {
        guard isSignedIn else {
            router.pending = albumID
            return
        }
        // A fresh signed-in tap supersedes any park: clear it synchronously
        // (before the resolve hop) so a concurrent drain can't replay the stale
        // parked id behind us.
        router.pending = nil
        await present(albumID: albumID)
    }

    /// Reconcile the deep-link surface with an auth-state transition — RootView
    /// calls this from `.onChange(of: auth.state)`, passing the old and new
    /// signed-in flags. Three cases:
    ///
    /// - **Now signed in** (cold-launch resolve, or a fresh sign-in): replay a
    ///   parked id into ``Router/deepLink``.
    /// - **Genuine sign-out** (was signed in, now isn't): tear down — dismiss any
    ///   presented cover and drop any park via ``invalidateDeepLink()`` — so a
    ///   deep-link detail can't strand over `LoginView` issuing 401s.
    /// - **Still signed out** (cold-launch `.unknown` → `.signedOut`, no
    ///   session): do nothing, so a tap parked before sign-in survives for a
    ///   later manual sign-in to replay.
    func handleAuthChange(wasSignedIn: Bool, isSignedIn: Bool) async {
        if isSignedIn {
            guard let albumID = router.pending else { return }
            // Capture-and-clear synchronously: the resolve below suspends, and
            // clearing now stops a second replay from re-reading the same park.
            router.pending = nil
            await present(albumID: albumID)
        } else if wasSignedIn {
            invalidateDeepLink()
        }
    }

    /// Tear down the deep-link surface on sign-out: dismiss the cover, drop any
    /// park, and bump ``presentationToken`` so an in-flight ``present(albumID:)``
    /// — one whose `resolveRoute` was still suspended when sign-out landed —
    /// bows out instead of re-presenting an album over `LoginView`.
    private func invalidateDeepLink() {
        presentationToken += 1
        router.deepLink = nil
        router.pending = nil
    }

    /// Resolve `albumID` to a route and present it — the single resolve→present
    /// step both deep-link entry points funnel through. `resolveRoute`'s `await`
    /// releases the main actor (a clone lookup can queue behind a multi-second
    /// `CatalogRefreshService` store replace), so two presentations can be in
    /// flight at once: a parked replay racing a fresh tap, or a sign-out landing
    /// mid-resolve. A monotonic token makes the **most-recently-requested**
    /// outcome win deterministically — rather than whichever store read resumes
    /// last — so a stale parked id (or a route resolved before sign-out) can't
    /// clobber a just-tapped one (or strand over `LoginView`).
    private func present(albumID: Int) async {
        // Already showing this exact album (e.g. a re-tap of the open cover):
        // nothing to present, and skip the redundant clone read.
        if router.deepLink?.id == albumID { return }
        presentationToken += 1
        let token = presentationToken
        let route = await resolveRoute(albumID: albumID)
        // A newer tap/sign-out bumped the token while we were resolving; bow out
        // so its fresher outcome is the one that lands.
        guard token == presentationToken else { return }
        router.deepLink = route
    }

    /// Build the route for `albumID`, looking up the cloned row for an instant
    /// header render. A clone hit carries the row's ``CatalogRow/detailFallback``
    /// so `AlbumDetailView` renders before `/library/info` resolves; a clone miss
    /// (no store, absent row, or a store read error) falls through to
    /// `fallback: nil`, which the detail view resolves by awaiting `/library/info`.
    private func resolveRoute(albumID: Int) async -> AlbumRoute {
        guard let catalogStore else { return AlbumRoute(id: albumID, fallback: nil) }
        // A thrown read and an absent row both collapse to "no fallback" — `try?`
        // already flattens the optional-returning call (SE-0230), so no `?? nil`.
        let row = try? await catalogStore.row(id: albumID)
        return AlbumRoute(id: albumID, fallback: row?.detailFallback)
    }

    /// A verbose, log-safe description of an error for the catalog-refresh failure
    /// path: the `NSError` domain + numeric code (so a Core Spotlight failure such
    /// as `CSIndexErrorDomain` `-1001` `CSIndexErrorCodeInvalidItemError` stays
    /// legible and greppable) plus any nested `underlyingErrors`.
    /// `localizedDescription` alone collapses all of that to "The operation
    /// couldn't be completed", which hides *which* attribute Core Spotlight
    /// rejected — exactly the detail we need when an index batch fails. `nonisolated`
    /// (it's pure) so the background catch and the unit tests can call it directly.
    nonisolated static func catalogErrorDetail(_ error: Error) -> String {
        let ns = error as NSError
        var detail = "\(ns.domain) code=\(ns.code): \(ns.localizedDescription)"
        if !ns.underlyingErrors.isEmpty {
            let nested = ns.underlyingErrors.map { underlying -> String in
                let u = underlying as NSError
                return "\(u.domain) code=\(u.code): \(u.localizedDescription)"
            }
            detail += " [underlying: \(nested.joined(separator: "; "))]"
        }
        return detail
    }

    /// Locate (creating if needed) `<Application Support>/<relativePath>/`.
    /// Application Support is the home for regenerable, app-managed data (in
    /// `Library`, excluded from the user's Documents and from iCloud backup of user
    /// content). Returns `nil` if the directory can't be located or created.
    static func appSupportSubdirectory(_ relativePath: String) -> URL? {
        let fileManager = FileManager.default
        guard let appSupport = try? fileManager.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        ) else {
            return nil
        }
        let directory = appSupport.appending(path: relativePath, directoryHint: .isDirectory)
        do {
            try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        } catch {
            catalogLog.error("Could not create directory at \(directory.path, privacy: .public): \(error.localizedDescription, privacy: .public)")
            return nil
        }
        return directory
    }

    /// The on-device catalog clone's SQLite file:
    /// `<Application Support>/Catalog/catalog.sqlite`. Returns `nil` (leaving the
    /// catalog features inert) if the directory can't be located or created.
    static func defaultCatalogStoreURL() -> URL? {
        appSupportSubdirectory("Catalog")?.appending(path: "catalog.sqlite", directoryHint: .notDirectory)
    }

    /// The on-device bin snapshot's SQLite file (issue #60):
    /// `<Application Support>/Bin/bin.sqlite`. A **separate** directory + DB from
    /// `Catalog/` — the bin store is its own independent actor. Returns `nil`
    /// (leaving the bin online-only) if the directory can't be located or created.
    static func defaultBinStoreURL() -> URL? {
        appSupportSubdirectory("Bin")?.appending(path: "bin.sqlite", directoryHint: .notDirectory)
    }

    /// The on-device Spotlight thumbnail cache directory (issue #44):
    /// `<Application Support>/Catalog/Thumbnails/`. Returns `nil` (-> no thumbnail
    /// provider, inert artwork feature) if it can't be located or created.
    static func defaultThumbnailDirectoryURL() -> URL? {
        appSupportSubdirectory("Catalog/Thumbnails")
    }

    static func resolveConfiguration(
        authString: String?,
        apiString: String?
    ) -> WXYCAPIConfiguration {
        // Neither key set — production is the intended default.
        if authString == nil && apiString == nil {
            return .production
        }

        // At least one key was provided; a misconfiguration here used to
        // silently fall back to production and hit the real backend during
        // local dev. Log loudly instead.
        guard let authString, let apiString else {
            configLog.warning(
                "Partial WXYCAPIConfiguration override: WXYCAuthBaseURL=\(authString ?? "<missing>", privacy: .public), WXYCAPIBaseURL=\(apiString ?? "<missing>", privacy: .public). Both keys must be set to override .production; falling back."
            )
            return .production
        }
        guard let authURL = URL(string: authString), let apiURL = URL(string: apiString) else {
            configLog.warning(
                "WXYCAPIConfiguration override has unparseable URL(s): WXYCAuthBaseURL=\(authString, privacy: .public), WXYCAPIBaseURL=\(apiString, privacy: .public). Falling back to .production."
            )
            return .production
        }
        return WXYCAPIConfiguration(authBaseURL: authURL, apiBaseURL: apiURL)
    }
}
