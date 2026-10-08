//
//  SceneDelegate.swift
//  WXYCDJ
//
//  Reliable deep-link delivery. A UIWindowSceneDelegate catches the Core
//  Spotlight CSSearchableItemActionType continuation (issue #19 step 7 fix) in
//  both states the flaky view-level .onContinueUserActivity was dropping, and
//  the listener app's wxycdj://album/<id> URL (issue #186): cold launch (both
//  arrive in scene(_:willConnectTo:)'s connectionOptions) and warm
//  (scene(_:continue:) / scene(_:openURLContexts:)). It forwards to the shared
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
/// sole purpose of receiving Spotlight continuation activities and
/// `wxycdj://` URLs. Scene-based apps
/// route `NSUserActivity` continuation through the scene, not
/// `UIApplication`'s `continue` method — and SwiftUI's `onContinueUserActivity`
/// was not delivering it here — so this is the path that actually fires.
///
/// It deliberately does **not** touch `window`: SwiftUI owns the window and the
/// view hierarchy. Implementing these callbacks only observes the launch /
/// continuation activities and hands them to ``AppDependencies``.
@MainActor
final class SceneDelegate: NSObject, UIWindowSceneDelegate {
    /// Cold launch: if a Spotlight tap or a `wxycdj://` link launched the app,
    /// it is here in `connectionOptions` (not via `scene(_:continue:)` or
    /// `scene(_:openURLContexts:)`). `restoreSession()`
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
        for context in connectionOptions.urlContexts {
            handle(context.url)
        }
    }

    /// Warm continuation: the app was already running when the DJ tapped a
    /// Spotlight result.
    func scene(_ scene: UIScene, continue userActivity: NSUserActivity) {
        handle(userActivity)
    }

    /// Warm open: the app was already running when the listener app opened a
    /// `wxycdj://album/<id>` link (issue #186).
    func scene(_ scene: UIScene, openURLContexts URLContexts: Set<UIOpenURLContext>) {
        for context in URLContexts {
            handle(context.url)
        }
    }

    /// Forward a `wxycdj://` URL to the shared composition root, which parses
    /// and routes it (or ignores it if malformed).
    private func handle(_ url: URL) {
        guard let dependencies = Self.appDependencies else {
            deepLinkLog.error("Listener-app link dropped: no AppDependencies on the app delegate")
            return
        }
        Task { await dependencies.handleListenerAppURL(url) }
    }

    /// Forward an activity to the shared composition root. Reaches it through
    /// ``appDependencies`` so the scene and the BGTask handler share one
    /// `AppDependencies` (and one `Router`/`CatalogRefreshService`).
    private func handle(_ activity: NSUserActivity) {
        guard let dependencies = Self.appDependencies else {
            deepLinkLog.error("Spotlight continuation dropped: no AppDependencies on the app delegate")
            return
        }
        Task { await dependencies.handleSpotlightContinuation(activity) }
    }

    /// The shared composition root the scene forwards to, read through
    /// ``AppDelegate/shared``. Not `UIApplication.shared.delegate as?
    /// AppDelegate`: under SwiftUI's adaptor that cast is always nil, which
    /// dropped every activity this delegate received.
    static var appDependencies: AppDependencies? {
        AppDelegate.shared?.dependencies
    }
}
