//
//  RootView.swift
//  WXYCDJ
//
//  Auth gate. Observes AuthService.state and shows LoginView or MainView. Also
//  hosts the Spotlight deep-link surface (issue #19 step 7): the
//  CSSearchableItemActionType continuation, the auth-replay drain, and the
//  fullScreenCover live here so they're active in every auth state — including
//  the cold-launch spinner, when a tap can arrive mid-restoreSession().
//
//  Created by Jake on 5/14/26.
//  Copyright © 2026 WXYC. All rights reserved.
//

import CoreSpotlight
import SwiftUI
import WXYCAPI

struct RootView: View {
    @Environment(AppDependencies.self) private var deps
    @Environment(AuthService.self) private var auth
    @Environment(Router.self) private var router

    var body: some View {
        // @Bindable so the cover can two-way bind $router.deepLink — dismissing
        // the cover clears it back to nil.
        @Bindable var router = router

        Group {
            switch auth.state {
            case .unknown, .signingIn:
                ProgressView()
                    .progressViewStyle(.circular)
            case .signedOut:
                LoginView()
            case .signedIn:
                MainView()
            }
        }
        // A Spotlight tap delivers an NSUserActivity carrying the item's
        // "album.<id>" identifier. Parse it and either present immediately (when
        // signed in) or stash for replay. Attached here, not in MainView, so a
        // tap during the cold-launch spinner / signed-out state isn't dropped.
        .onContinueUserActivity(CSSearchableItemActionType) { activity in
            guard let identifier = activity.userInfo?[CSSearchableItemActivityIdentifier] as? String,
                  let albumID = CatalogSpotlight.albumID(from: identifier) else { return }
            Task { await deps.handleSpotlightTap(albumID: albumID, isSignedIn: auth.isSignedIn) }
        }
        // Cold-launch replay: a tap that landed before sign-in resolved parked
        // its id in Router.pending. State is Equatable, so this fires on EVERY
        // transition — including sign-out and JWT rotation (a re-derived payload
        // is a new .signedIn state). drainPendingDeepLink is idempotent (it
        // guards on isSignedIn && a non-nil pending), which is exactly what makes
        // the over-firing harmless. Do NOT "optimize" this into `if case
        // .signedIn` keyed on a one-shot — that reintroduces the cold-launch race
        // where a tap arriving mid-restoreSession() is dropped.
        .onChange(of: auth.state) {
            Task { await deps.drainPendingDeepLink(isSignedIn: auth.isSignedIn) }
        }
        // The deep-linked detail lives in its own cover (own NavigationStack),
        // never on the Search/Bin tab stacks — so dismissing returns the DJ to
        // the exact tab + scroll position they left. Known limitation: a second
        // Spotlight tap while a cover is already up is a silent no-op until the
        // open cover is dismissed — fullScreenCover(item:) only watches
        // nil↔non-nil, not an identity swap. Two consecutive taps without an
        // intervening dismiss is rare enough to accept.
        .fullScreenCover(item: $router.deepLink) { route in
            // Re-inject the composition root: fullScreenCover content is hosted
            // in a separate presentation context that does NOT inherit the
            // presenter's .environment(_:)-injected @Observable objects, and
            // AlbumDetailView reads AppDependencies. (auth/router aren't read in
            // this subtree, so they're not re-injected.)
            DeepLinkAlbumCover(route: route)
                .environment(deps)
        }
    }
}
