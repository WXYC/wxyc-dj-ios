//
//  AppDelegate.swift
//  WXYCDJ
//
//  A minimal UIApplicationDelegate that exists for two reasons. Issue #19
//  step 5: register the catalog-reindex BGProcessingTask launch handler, which
//  SwiftUI's .backgroundTask scene modifier can't (it has no .processing
//  matcher). It also owns the single AppDependencies instance so the foreground
//  path and both background legs share ONE CatalogRefreshService — required for
//  its single-flight (no two Spotlight batches at once) guarantee. Issue #106:
//  starts Sentry before that composition root is built, so its own store-open
//  failures (SQLite unavailable -> degraded catalog/bin features) are visible.
//  Issue #108 starts PostHog right after, into dj-site's shared project; see
//  TelemetryBootstrap.startAnalytics().
//
//  Created by Jake on 06/23/26.
//  Copyright © 2026 WXYC. All rights reserved.
//

import UIKit

@MainActor
final class AppDelegate: NSObject, UIApplicationDelegate {
    /// The app-wide composition root. Owned here (not in the App's `@State`) so
    /// the BGProcessingTask handler registered below and the SwiftUI scene drive
    /// the same `CatalogRefreshService` instance.
    let dependencies: AppDependencies

    /// Issue #138's lock-screen transport registration. Held as a stored
    /// property rather than called statically because it retains the
    /// `addTarget` handles that `removeTarget(_:)` needs — see
    /// `RemoteCommandCenterRegistrar`'s header for why discarding them would
    /// strand a `.noSuchContent` no-op on every command at issue #145.
    private let remoteCommands = RemoteCommandCenterRegistrar()

    override init() {
        // Must run before `AppDependencies()` below: its designated
        // initializer's store-open failures are exactly the silent field
        // failure issue #106 exists to see, so telemetry has to be live
        // first. This is also why `dependencies` moved from a default-value
        // stored property to an assignment here -- a default-value property
        // initializer runs before `init()`'s body, which would build
        // AppDependencies (and its real SentryErrorReporter) before this line
        // ever ran.
        TelemetryBootstrap.start()
        // Issue #108: product analytics, into dj-site's shared PostHog project
        // (see TelemetryBootstrap.startAnalytics's doc comment).
        TelemetryBootstrap.startAnalytics()
        self.dependencies = AppDependencies()
        super.init()
    }

    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        // Must register before launch finishes. The poll leg
        // (BGAppRefreshTask) is registered separately by SwiftUI's
        // .backgroundTask(.appRefresh:) modifier on the scene.
        CatalogBackgroundTasks.registerReindexHandler(dependencies: dependencies)
        // Issue #138 registers the no-ops (and, in the same call, disables
        // every unsupported transport command -- that half doesn't change
        // here). Issue #145: a real PlaybackController now exists, so wire
        // it in immediately -- registerPlaybackCommands(controller:) detaches
        // the no-ops before installing real handlers, per this type's
        // standing obligation.
        remoteCommands.registerNoOpCommands()
        remoteCommands.registerPlaybackCommands(controller: dependencies.playbackController)
        return true
    }

    /// Attach ``SceneDelegate`` to SwiftUI's window scene so it receives Spotlight
    /// continuation activities (issue #19 step 7 fix). Only `delegateClass` is
    /// set — no `sceneClass`, no storyboard — so SwiftUI keeps owning the window
    /// and hosting `RootView`; the delegate just observes the launch /
    /// continuation activities the view-level `onContinueUserActivity` was
    /// dropping in both cold and warm states.
    func application(
        _ application: UIApplication,
        configurationForConnecting connectingSceneSession: UISceneSession,
        options: UIScene.ConnectionOptions
    ) -> UISceneConfiguration {
        let configuration = UISceneConfiguration(
            name: nil,
            sessionRole: connectingSceneSession.role
        )
        configuration.delegateClass = SceneDelegate.self
        return configuration
    }
}
