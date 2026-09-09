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
                        // Only an .active that follows a real .background is a
                        // foreground re-entry (issue #118 item 4). The cold
                        // launch's own inactive -> active lands here alongside
                        // the .task above, and so does an inactive -> active
                        // blip from Control Centre or the app switcher --
                        // neither is a return from background, and refreshing
                        // for the first would fire catalog_refresh_completed
                        // twice for one launch.
                        guard foregroundReentry.isGenuineForegroundReentry() else { return }
                        Task { await dependencies.refreshCatalog(trigger: .foreground) }
                    case .background:
                        // Arm the background poll for while we're away (only if
                        // there's a catalog to refresh); it re-arms itself
                        // thereafter.
                        dependencies.scheduleBackgroundRefreshIfAvailable()
                        // ...and record that we genuinely left, which is what
                        // makes the next .active a re-entry rather than a blip.
                        foregroundReentry.noteBackground()
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

/// Tells a genuine foreground re-entry apart from the other ways SwiftUI
/// reports `.active` (issue #118 item 4). `WXYCDJApp`'s launch `.task` and its
/// `.onChange(of: scenePhase)` both observe the same cold-launch
/// `inactive -> active` transition — the `.task` because it runs on the
/// scene's first appearance, the `onChange` because that IS the scene becoming
/// active — so without this, a cold launch fired `catalog_refresh_completed`
/// twice: once `.launch`, once `.foreground`. Worse than a constant
/// double-count, the `.foreground` leg's outcome was *inconsistent* — it often
/// outran the `.task`'s `restoreSession()` and hit the silent `.notSignedIn`
/// skip, so whether the second event fired at all depended on scheduling.
///
/// **The rule is "an `.active` counts only after a `.background`," not
/// "ignore the first `.active`"** — and the difference is load-bearing twice
/// over (issue #118 review):
///
/// - *It does not assume the cold-launch `.active` is delivered.* Whether
///   SwiftUI raises `onChange(of: scenePhase)` for the launch activation is
///   not contractually guaranteed. Consuming the first `.active`
///   unconditionally is correct only if it always fires; if it ever doesn't,
///   that rule eats the first **genuine** re-entry instead and
///   `refreshCatalog(trigger: .foreground)` silently never runs on the first
///   return from background — a functional regression, not just a miscount.
///   Keying on a seen `.background` is right under both behaviours.
/// - *It ignores an `inactive -> active` blip.* Pulling down Control Centre,
///   entering the app switcher, or taking a call drives `.active -> .inactive
///   -> .active` without ever reaching `.background`. That is not a return
///   from background and there is nothing to top up.
///
/// A timing-based fix (e.g. "skip `.active` if `restoreSession()` hasn't
/// finished yet") would inherit the original race. This is race-free: it reads
/// only which phases have been observed, never how long concurrent async work
/// took.
///
/// Deliberately no SwiftUI/scenePhase dependency, so it's unit-testable as a
/// plain state machine (`WXYCDJTests/ForegroundReentryTrackerTests`) without
/// standing up a scene.
struct ForegroundReentryTracker: Sendable {
    private var hasSeenBackground = false

    /// Call on every `.background` scenePhase transition.
    mutating func noteBackground() {
        hasSeenBackground = true
    }

    /// Call on every `.active` scenePhase transition. `true` only once the app
    /// has actually been backgrounded — so the cold-launch activation (already
    /// covered by the launch `.task`) and any `inactive -> active` blip both
    /// answer `false`.
    ///
    /// Non-mutating: unlike the first shape this had, the decision is a pure
    /// read of observed phases and consumes nothing, so calling it twice for
    /// one transition can't change the answer.
    func isGenuineForegroundReentry() -> Bool {
        hasSeenBackground
    }
}
