//
//  Router.swift
//  WXYCDJ
//
//  Deep-link state for the Spotlight tap-through (issue #19 step 7). Owned by
//  AppDependencies, injected via .environment, and read by RootView, which
//  binds a fullScreenCover to `deepLink`, replays `pending` once auth resolves
//  to .signedIn, and drains `queued` from the cover's onDismiss (issue #126).
//
//  Created by Jake on 6/23/26.
//  Copyright © 2026 WXYC. All rights reserved.
//

import Observation

/// Holds the one in-flight Spotlight deep link. Three slots, at most one set:
///
/// - ``deepLink`` is the resolved route currently presented in RootView's
///   `fullScreenCover`. Setting it presents the album's detail in its own
///   `NavigationStack`; the cover's Close button (and `dismiss`) clears it back
///   to `nil`, returning the DJ to the exact tab + scroll position they left.
/// - ``pending`` is the parked album id from a tap that arrived while signed out
///   or mid-`restoreSession()`. RootView drains it into ``deepLink`` (with a
///   local-clone `fallback` lookup) the moment auth flips to `.signedIn`.
/// - ``queued`` is an album waiting behind a cover's dismissal (issue #126): a
///   tap for a different album while a cover is showing queues itself and nils
///   ``deepLink``, and the cover's `onDismiss` presents it. Deliberately not a
///   reuse of ``pending``, which `handleAuthChange` replays — conflating the
///   two would let an auth transition replay a swap.
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

    /// An album id waiting for the current cover's dismissal to finish (issue
    /// #126). Set only while ``deepLink`` is `nil` mid-dismissal; drained by
    /// the cover's `onDismiss`, and cleared on sign-out.
    var queued: Int?
}
