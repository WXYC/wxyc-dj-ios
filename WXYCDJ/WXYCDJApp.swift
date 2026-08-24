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
                        // Re-entry from background: top up the clone.
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
