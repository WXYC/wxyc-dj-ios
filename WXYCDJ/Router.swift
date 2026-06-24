//
//  Router.swift
//  WXYCDJ
//
//  Cold-launch deep-link state for the Spotlight tap-through (issue #19 step 7).
//  Owned by AppDependencies, injected via .environment, and read by RootView,
//  which binds a fullScreenCover to `deepLink` and replays `pending` once auth
//  resolves to .signedIn.
//
//  Created by Jake on 6/23/26.
//  Copyright © 2026 WXYC. All rights reserved.
//

import Observation

/// Holds the one in-flight Spotlight deep link. Two slots, never both set:
///
/// - ``deepLink`` is the resolved route currently presented in RootView's
///   `fullScreenCover`. Setting it presents the album's detail in its own
///   `NavigationStack`; the cover's Close button (and `dismiss`) clears it back
///   to `nil`, returning the DJ to the exact tab + scroll position they left.
/// - ``pending`` is the parked album id from a tap that arrived while signed out
///   or mid-`restoreSession()`. RootView drains it into ``deepLink`` (with a
///   local-clone `fallback` lookup) the moment auth flips to `.signedIn`.
///
/// State only — the clone lookup that turns a `pending` id into a `deepLink`
/// route lives on ``AppDependencies`` (it owns the catalog store). `@MainActor`
/// so SwiftUI observes it directly.
@MainActor
@Observable
final class Router {
    /// The resolved deep-link route bound to RootView's `fullScreenCover`. `nil`
    /// when nothing is presented.
    var deepLink: AlbumRoute?

    /// An album id parked from a Spotlight tap that landed before sign-in
    /// resolved. Drained into ``deepLink`` on the flip to `.signedIn`; `nil`
    /// once replayed (or when the tap was handled immediately).
    var pending: Int?
}
