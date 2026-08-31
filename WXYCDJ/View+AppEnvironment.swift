//
//  View+AppEnvironment.swift
//  WXYCDJ
//
//  One place that injects the app-wide observable objects (composition root +
//  AuthService + Router + ConnectivityMonitor) into the SwiftUI environment.
//  Applied at the scene root AND re-applied to the Spotlight deep-link
//  `fullScreenCover` content (issue #19 step 7), which is hosted in a separate
//  presentation context that does NOT inherit the presenter's
//  `.environment(_:)`-injected @Observable objects — so the two sites share one
//  helper and can't drift.
//
//  Created by Jake on 6/23/26.
//  Copyright © 2026 WXYC. All rights reserved.
//

import SwiftUI

extension View {
    /// Inject the app-wide `@Observable` objects every screen reads from
    /// `@Environment`: the ``AppDependencies`` composition root, its
    /// `AuthService`, its `Router`, and its `ConnectivityMonitor` (issue #56,
    /// read by the offline banner), and its `PlaybackController` (issue #144).
    /// Used at the scene root and re-applied to
    /// the deep-link cover so the shared `AlbumDetailView` runs under an
    /// identical environment whether it's reached via a tab push or a Spotlight
    /// tap — a single source of truth for what the UI environment contains.
    func wxycAppEnvironment(_ dependencies: AppDependencies) -> some View {
        environment(dependencies)
            .environment(dependencies.authService)
            .environment(dependencies.router)
            .environment(dependencies.connectivity)
            .environment(dependencies.playbackController)
    }
}
