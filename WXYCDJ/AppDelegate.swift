//
//  AppDelegate.swift
//  WXYCDJ
//
//  A minimal UIApplicationDelegate that exists for exactly one reason (issue #19
//  step 5): register the catalog-reindex BGProcessingTask launch handler, which
//  SwiftUI's .backgroundTask scene modifier can't (it has no .processing
//  matcher). It also owns the single AppDependencies instance so the foreground
//  path and both background legs share ONE CatalogRefreshService — required for
//  its single-flight (no two Spotlight batches at once) guarantee.
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
    let dependencies = AppDependencies()

    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        // Must register before launch finishes. The poll leg
        // (BGAppRefreshTask) is registered separately by SwiftUI's
        // .backgroundTask(.appRefresh:) modifier on the scene.
        CatalogBackgroundTasks.registerReindexHandler(dependencies: dependencies)
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
