//
//  SceneDelegate.swift
//  WXYCDJ
//
//  Reliable Core Spotlight deep-link delivery (issue #19 step 7 fix). A
//  UIWindowSceneDelegate catches the CSSearchableItemActionType continuation in
//  both states the flaky view-level .onContinueUserActivity was dropping:
//  cold launch (the launch activity arrives in scene(_:willConnectTo:)'s
//  connectionOptions) and warm (scene(_:continue:)). It forwards to the shared
//  AppDependencies; it never creates a window, so SwiftUI's WindowGroup keeps
//  hosting the UI.
//
//  Created by Jake on 06/23/26.
//  Copyright © 2026 WXYC. All rights reserved.
//

import OSLog
import UIKit

private let deepLinkLog = Logger(subsystem: "org.wxyc.dj", category: "deeplink")

/// Scene delegate attached to SwiftUI's window scene (via
/// ``AppDelegate/application(_:configurationForConnecting:options:)``) for the
/// sole purpose of receiving Spotlight continuation activities. Scene-based apps
/// route `NSUserActivity` continuation through the scene, not
/// `UIApplication`'s `continue` method — and SwiftUI's `onContinueUserActivity`
/// was not delivering it here — so this is the path that actually fires.
///
/// It deliberately does **not** touch `window`: SwiftUI owns the window and the
/// view hierarchy. Implementing these callbacks only observes the launch /
/// continuation activities and hands them to ``AppDependencies``.
@MainActor
final class SceneDelegate: NSObject, UIWindowSceneDelegate {
    /// Cold launch: if a Spotlight tap launched the app, the activity is here in
    /// `connectionOptions` (not via `scene(_:continue:)`). `restoreSession()`
    /// hasn't resolved yet, so the tap parks and replays once auth flips to
    /// `.signedIn` — exactly the path ``AppDependencies/handleAuthChange`` covers.
    func scene(
        _ scene: UIScene,
        willConnectTo session: UISceneSession,
        options connectionOptions: UIScene.ConnectionOptions
    ) {
        for activity in connectionOptions.userActivities {
            handle(activity)
        }
    }

    /// Warm continuation: the app was already running when the DJ tapped a
    /// Spotlight result.
    func scene(_ scene: UIScene, continue userActivity: NSUserActivity) {
        handle(userActivity)
    }

    /// Forward an activity to the shared composition root. Reaches it through the
    /// `AppDelegate` so the scene and the BGTask handler share one
    /// `AppDependencies` (and one `Router`/`CatalogRefreshService`).
    private func handle(_ activity: NSUserActivity) {
        guard let dependencies = (UIApplication.shared.delegate as? AppDelegate)?.dependencies else {
            deepLinkLog.error("Spotlight continuation dropped: no AppDependencies on the app delegate")
            return
        }
        Task { await dependencies.handleSpotlightContinuation(activity) }
    }
}
