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

@MainActor
@Observable
final class AppDependencies {
    let configuration: WXYCAPIConfiguration
    let authService: AuthService
    let api: APIClient
    /// The id-keyed on-device catalog clone (issue #19). `nil` only if the
    /// SQLite store couldn't be opened (disk unwritable) — the app degrades to
    /// in-app-only search rather than crashing. The Spotlight deep-link (step 7)
    /// reads it for an O(1) id→row `fallback` lookup.
    let catalogStore: (any CatalogStore)?
    /// The single shared refresh service the foreground path and both background
    /// tasks drive. **Exactly one instance** app-wide: its actor single-flights
    /// overlapping refreshes, which is what keeps `RealSearchableIndex`'s
    /// `@unchecked Sendable` sound (no two Spotlight batches open at once). `nil`
    /// when ``catalogStore`` is.
    let catalogRefreshService: CatalogRefreshService?

    convenience init() {
        self.init(catalogStoreURL: Self.defaultCatalogStoreURL())
    }

    /// Designated initializer. `catalogStoreURL` is the SQLite clone's path
    /// (injected in tests; the default points under Application Support). A `nil`
    /// URL, or a store that fails to open, leaves the catalog features inert.
    init(catalogStoreURL: URL?) {
        let bundle = Bundle.main
        let configuration = Self.resolveConfiguration(
            authString: bundle.object(forInfoDictionaryKey: "WXYCAuthBaseURL") as? String,
            apiString: bundle.object(forInfoDictionaryKey: "WXYCAPIBaseURL") as? String
        )
        self.configuration = configuration
        let authService = AuthService(configuration: configuration)
        self.authService = authService
        let api = APIClient(configuration: configuration, authService: authService)
        self.api = api

        // Catalog clone + Spotlight index. Store construction can fail (disk
        // unwritable); degrade to no catalog features rather than crash. One
        // CatalogRefreshService wraps the store + a live named CSSearchableIndex.
        if let catalogStoreURL {
            do {
                let store = try SQLiteCatalogStore(url: catalogStoreURL)
                let indexer = SpotlightCatalogIndexer()
                self.catalogStore = store
                self.catalogRefreshService = CatalogRefreshService(client: api, store: store, indexer: indexer)
            } catch {
                catalogLog.error("Catalog store unavailable at \(catalogStoreURL.path, privacy: .public): \(error.localizedDescription, privacy: .public). Falling back to in-app-only search.")
                self.catalogStore = nil
                self.catalogRefreshService = nil
            }
        } else {
            self.catalogStore = nil
            self.catalogRefreshService = nil
        }
    }

    // MARK: Catalog refresh

    /// Best-effort foreground/reindex refresh: poll → `304`/`200` → store-replace
    /// → Spotlight-reindex via the shared service. Logs the outcome. A missing or
    /// expired session (`APIError.notSignedIn`) is a **silent skip** — never an
    /// error banner, never a sign-in prompt. Called from the launch/foreground
    /// `.task`, on scene-activation, and (via the reindex BGTask) in the
    /// background.
    func refreshCatalog() async {
        guard let catalogRefreshService else { return }
        do {
            let outcome = try await catalogRefreshService.refresh()
            catalogLog.info("Catalog refresh: \(String(describing: outcome), privacy: .public)")
        } catch APIError.notSignedIn {
            catalogLog.debug("Catalog refresh skipped: not signed in")
        } catch {
            catalogLog.error("Catalog refresh failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// The `BGAppRefreshTask` poll leg: re-arm the next poll first (so even a
    /// thrown poll or a missing session reschedules), then do the cheap
    /// conditional GET; on a `200` submit the charging-gated reindex
    /// `BGProcessingTask` rather than reindexing on the ~30 s app-refresh budget.
    /// A missing/expired session is a silent skip + reschedule.
    func handleBackgroundPoll() async {
        CatalogBackgroundTasks.scheduleNextPoll()
        guard let catalogRefreshService else { return }
        do {
            if try await catalogRefreshService.poll() {
                CatalogBackgroundTasks.scheduleReindex()
            }
        } catch APIError.notSignedIn {
            catalogLog.debug("Background catalog poll skipped: not signed in")
        } catch {
            catalogLog.error("Background catalog poll failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// The on-device catalog clone's SQLite file:
    /// `<Application Support>/Catalog/catalog.sqlite`. Application Support is the
    /// home for regenerable, app-managed data (in `Library`, excluded from the
    /// user's Documents and from iCloud backup of user content). Returns `nil` if
    /// the directory can't be located or created, which leaves the catalog
    /// features inert.
    static func defaultCatalogStoreURL() -> URL? {
        let fileManager = FileManager.default
        guard let appSupport = try? fileManager.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        ) else {
            return nil
        }
        let directory = appSupport.appending(path: "Catalog", directoryHint: .isDirectory)
        do {
            try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        } catch {
            catalogLog.error("Could not create catalog directory at \(directory.path, privacy: .public): \(error.localizedDescription, privacy: .public)")
            return nil
        }
        return directory.appending(path: "catalog.sqlite", directoryHint: .notDirectory)
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
