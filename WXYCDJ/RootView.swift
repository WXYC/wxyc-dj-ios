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
    @Environment(ConnectivityMonitor.self) private var connectivity

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
        // Offline banner (issue #56): overlays the primary screens while offline
        // and auto-hides when ConnectivityMonitor flips back online. The banner
        // renders nothing when online, so the inset reserves no space. Hoisted
        // onto the always-mounted Group so it's live in every auth state.
        .safeAreaInset(edge: .top, spacing: 0) {
            OfflineBanner()
        }
        // A Spotlight tap delivers an NSUserActivity carrying the item's
        // "album.<id>" identifier; handleSpotlightContinuation parses it and
        // either presents immediately (signed in) or stashes for replay.
        //
        // NOTE: this view-level modifier is a FALLBACK. The primary, reliable
        // delivery is `SceneDelegate` — this modifier was not firing for the
        // CSSearchableItemActionType activity in either cold or warm state, which
        // is the bug it caused. Both paths funnel through the same
        // `handleSpotlightContinuation`, so a double-delivery is a harmless no-op
        // (present() early-outs on the already-shown album). Kept until the
        // scene-delegate path is confirmed on device, then it can be removed.
        .onContinueUserActivity(CSSearchableItemActionType) { activity in
            Task { await deps.handleSpotlightContinuation(activity) }
        }
        // Reconcile the deep link with every auth transition (old → new). On the
        // flip to signed-in (cold-launch resolve or a fresh sign-in) a parked tap
        // replays into the cover; on a genuine sign-out (was signed in, now not)
        // the cover is torn down so a detail can't strand over LoginView; a
        // cold-launch .unknown → .signedOut keeps the park for a later sign-in.
        // The old/new flags are why this needs both values, not just the new one.
        // Do NOT collapse this to a one-shot keyed on the first signed-in — that
        // reintroduces the race where a tap arriving mid-restoreSession() is
        // dropped. (A routine JWT refresh does NOT fire this: AuthService.refreshJWT
        // updates only the cached token, never `state`, so .signedIn keeps its
        // original payload and stays Equatable-equal.)
        .onChange(of: auth.state) { oldState, newState in
            Task {
                await deps.handleAuthChange(
                    wasSignedIn: oldState.isSignedIn,
                    isSignedIn: newState.isSignedIn
                )
            }
        }
        // Issue #108's two connectivity events. Deliberately sourced from
        // this onChange, not ConnectivityMonitor.reconnects: that stream is a
        // single-consumer AsyncStream issue #61's queued-bin flush is
        // documented to claim, and there is no offline-edge stream at all —
        // this needs both edges and must not race a future #61 consumer for
        // the online one. ConnectivityTransition.classify is the pure
        // decision (unit-tested independent of this otherwise-untestable
        // SwiftUI wiring, the same carve-out AlbumDetailView's four events
        // have — see CLAUDE.md's Telemetry section).
        .onChange(of: connectivity.isOnline) { wasOnline, isOnline in
            guard let transition = ConnectivityTransition.classify(wasOnline: wasOnline, isOnline: isOnline) else { return }
            deps.analytics.capture(transition.event)
        }
        // The deep-linked detail lives in its own cover (own NavigationStack),
        // never on the Search/Bin tab stacks — so dismissing returns the DJ to
        // the exact tab + scroll position they left. Known limitation: a second
        // Spotlight tap while a cover is already up is a silent no-op until the
        // open cover is dismissed — fullScreenCover(item:) only watches
        // nil↔non-nil, not an identity swap. Two consecutive taps without an
        // intervening dismiss is rare enough to accept.
        .fullScreenCover(item: $router.deepLink) { route in
            // fullScreenCover content is hosted in a separate presentation
            // context that does NOT inherit the presenter's
            // .environment(_:)-injected @Observable objects. Re-inject the SAME
            // trio WXYCDJApp injects at the root (one shared helper, so the two
            // sites can't drift) — the shared AlbumDetailView then runs under an
            // identical environment whether reached here or pushed onto a tab
            // stack, so a future auth/router read can't crash only on this path.
            DeepLinkAlbumCover(route: route)
                .wxycAppEnvironment(deps)
        }
    }
}
