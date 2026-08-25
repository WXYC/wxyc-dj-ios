//
//  WXYCDJApp.swift
//  WXYCDJ
//
//  App entry point. A minimal AppDelegate owns the single AppDependencies
//  (AuthService + APIClient + catalog clone/refresh) and registers the reindex
//  BGProcessingTask; RootView reads them from the environment. Catalog refresh
//  runs on launch/foreground (primary) and via background tasks (best-effort).
//
//  Created by Jake on 5/14/26.
//  Copyright © 2026 WXYC. All rights reserved.
//

import SwiftUI
import WXYCAPI

@main
struct WXYCDJApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @Environment(\.scenePhase) private var scenePhase
    // Issue #118 item 4: distinguishes the cold-launch `.active` transition
    // (already covered by the launch `.task` below) from a genuine
    // foreground re-entry, so `.onChange(of: scenePhase)` doesn't double-fire
    // `catalog_refresh_completed` on every cold launch. See the tracker's
    // doc comment for why this beat a timing-based fix.
    @State private var foregroundReentry = ForegroundReentryTracker()

    var body: some Scene {
        // Capture the shared composition root on the main actor so the off-main
        // .backgroundTask closure can hold it (AppDependencies is @MainActor, so
        // Sendable). One instance, shared with the AppDelegate's BGTask handler.
        let dependencies = appDelegate.dependencies

        return WindowGroup {
            RootView()
                .wxycAppEnvironment(dependencies)
                .task {
                    // Begin tracking the network path so the offline banner
                    // (issue #56) reflects real reachability from launch.
                    dependencies.startConnectivityMonitoring()
                    // Foreground-primary refresh: restore the session, then clone
                    // the catalog (a no-op skip until signed in).
                    await dependencies.authService.restoreSession()
                    await dependencies.refreshCatalog(trigger: .launch)
                }
                .onChange(of: scenePhase) { _, phase in
                    switch phase {
                    case .active:
                        // Cold launch's own inactive -> active transition lands
                        // here too, alongside the .task above -- consume it
                        // without refreshing so a cold launch fires exactly one
                        // catalog_refresh_completed, not two (issue #118 item 4).
                        // Every transition after the first is a genuine
                        // foreground re-entry: top up the clone.
                        guard foregroundReentry.isGenuineForegroundReentry() else { return }
                        Task { await dependencies.refreshCatalog(trigger: .foreground) }
                    case .background:
                        // Arm the background poll for while we're away (only if
                        // there's a catalog to refresh); it re-arms itself
                        // thereafter.
                        dependencies.scheduleBackgroundRefreshIfAvailable()
                    default:
                        break
                    }
                }
        }
        // Poll leg (BGAppRefreshTask). SwiftUI registers the handler; the closure
        // runs off the main actor. It re-arms, polls conditionally, and on a 200
        // submits the charging-gated reindex BGProcessingTask.
        .backgroundTask(.appRefresh(CatalogBackgroundTasks.pollIdentifier)) {
            await dependencies.handleBackgroundPoll()
        }
    }
}

/// Tells a cold-launch `.active` scene-phase transition apart from a genuine
/// foreground re-entry (issue #118 item 4). `WXYCDJApp`'s launch `.task` and
/// its `.onChange(of: scenePhase)` both observe the same cold-launch
/// `inactive -> active` transition — the `.task` because it runs on the
/// scene's first appearance, the `onChange` because that IS the scene
/// becoming active — so without this, a cold launch fired
/// `catalog_refresh_completed` twice: once `.launch`, once `.foreground`.
/// Worse than a constant double-count, the `.foreground` leg's outcome was
/// *inconsistent* — it often outran the `.task`'s `restoreSession()` and hit
/// the silent `.notSignedIn` skip, so whether the second event fired at all
/// depended on scheduling.
///
/// A timing-based fix (e.g. "skip `.active` if `restoreSession()` hasn't
/// finished yet") would inherit that same race. This is race-free instead:
/// exactly one `.active` transition occurs during the app's cold-launch
/// sequence (`inactive -> active`), and every subsequent background ->
/// active cycle produces exactly one more. Consuming the *first* `.active`
/// call, unconditionally and synchronously, is therefore precise regardless
/// of how long any concurrent async work takes.
///
/// Deliberately no SwiftUI/scenePhase dependency, so it's unit-testable as a
/// plain state machine (`WXYCDJTests/ForegroundReentryTrackerTests`) without
/// standing up a scene.
struct ForegroundReentryTracker: Sendable {
    private var hasConsumedLaunchActivation = false

    /// Call on every `.active` scenePhase transition. Returns `false` only
    /// on the first call (the cold-launch activation, already covered by the
    /// launch `.task`); every call after that is a genuine foreground
    /// re-entry and returns `true`.
    mutating func isGenuineForegroundReentry() -> Bool {
        guard hasConsumedLaunchActivation else {
            hasConsumedLaunchActivation = true
            return false
        }
        return true
    }
}
