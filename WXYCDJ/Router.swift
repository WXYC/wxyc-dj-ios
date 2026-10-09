//
//  Router.swift
//  WXYCDJ
//
//  Deep-link state for the Spotlight tap-through (issue #19 step 7). Owned by
//  AppDependencies, injected via .environment, and read by RootView, which
//  binds a fullScreenCover to `deepLink`, replays `pending` once auth resolves
//  to .signedIn, and presents a link held during the DJ's Close from the
//  cover's onDismiss (`dismissal`, issue #126).
//  Each slot carries the link's source (issue #185), so the cover and the
//  analytics event can name where the link came from.
//
//  Created by Jake on 6/23/26.
//  Copyright © 2026 WXYC. All rights reserved.
//

import Observation

/// Where a deep link came from. Threaded from the entry point, through the
/// park and a link held during a Close, to the presentation, so `DeepLinkAlbumCover` and
/// `present`'s analytics event name the right source rather than assuming one.
/// Every consumer switches over it with no `default:`, so a new source is a
/// compile-time decision at each.
enum DeepLinkSource: Equatable, Sendable {
    /// A home-screen Spotlight tap (issue #19 step 7).
    case spotlight
    /// A `wxycdj://album/<id>` link, opened by the listener app's "Open in
    /// WXYC DJ" button (issue #186).
    case listenerApp
}

/// An album a deep link asked for, and where the link came from. The type of
/// both ``Router/pending`` and a link held in ``Router/dismissal``: the two
/// *slots* stay separate (one is replayed on sign-in, the other when the DJ's
/// Close finishes), only the shape is shared — hence a name that says neither.
struct DeepLinkRequest: Equatable, Sendable {
    let albumID: Int
    let source: DeepLinkSource
}

/// The route on screen in RootView's deep-link cover, plus the source that
/// opened it. The source lives here rather than on ``AlbumRoute`` because
/// `AlbumRoute` is also the Search/Bin `NavigationStack` path value, where a
/// presentation source means nothing. Identity is the album id, as the cover's
/// `fullScreenCover(item:)` binding needs.
struct PresentedDeepLink: Identifiable {
    let route: AlbumRoute
    let source: DeepLinkSource
    var id: Int { route.id }
}

/// The DJ's Close of the deep-link cover, from the tap until SwiftUI's
/// `onDismiss` reports the cover gone. `next` is a link that arrived in that
/// window, held so it isn't presented into a cover that is animating out.
struct CoverDismissal: Equatable, Sendable {
    var next: DeepLinkRequest?
    /// Whether `next` was a parked replay, so the event it records keeps
    /// `parked: true` when the dismissal presents it.
    var nextParked = false
}

/// Holds the one in-flight deep link. Three slots:
///
/// - ``deepLink`` is the resolved route (and its source) currently presented in RootView's
///   `fullScreenCover`. Setting it presents the album's detail in its own
///   `NavigationStack`; the cover's Close button (and `dismiss`) clears it back
///   to `nil`, returning the DJ to the exact tab + scroll position they left.
/// - ``pending`` is the parked request from a link that arrived while signed out
///   or mid-`restoreSession()`. RootView drains it into ``deepLink`` (with a
///   local-clone `fallback` lookup) the moment auth flips to `.signedIn`.
/// - ``dismissal`` is set while the cover the DJ closed is animating out (issue
///   #126), and holds a link that arrived meanwhile for the cover's `onDismiss`
///   to present. Only the DJ's Close sets it, never a swap or a sign-out, so it
///   is set only for a cover that was on screen and whose `onDismiss` is
///   therefore guaranteed to fire and clear it. A swap needs no slot: writing
///   a different album into ``deepLink`` makes `fullScreenCover(item:)`
///   dismiss the old cover and present the new one.
///
/// State only — the clone lookup that turns a `pending` id into a `deepLink`
/// route lives on ``AppDependencies`` (it owns the catalog store). `@MainActor`
/// so SwiftUI observes it directly.
@MainActor
@Observable
final class Router {
    /// The resolved deep-link route bound to RootView's `fullScreenCover`. `nil`
    /// when nothing is presented.
    var deepLink: PresentedDeepLink?

    /// A request parked from a link that landed before sign-in
    /// resolved. Drained into ``deepLink`` on the flip to `.signedIn`; `nil`
    /// once replayed (or when the tap was handled immediately).
    var pending: DeepLinkRequest?

    /// The DJ's Close in progress, and any link held behind it (issue #126).
    /// `nil` when no Close is animating.
    var dismissal: CoverDismissal?
}
