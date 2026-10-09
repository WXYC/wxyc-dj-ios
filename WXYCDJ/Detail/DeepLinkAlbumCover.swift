//
//  DeepLinkAlbumCover.swift
//  WXYCDJ
//
//  The Spotlight deep-link surface (issue #19 step 7): a tapped album's detail
//  presented in its OWN NavigationStack inside RootView's fullScreenCover —
//  deliberately not pushed onto the Search/Bin tab stacks, so it never pollutes
//  their navigation/scroll state, never fabricates a Back target, and dodges the
//  TabView-selection-vs-NavigationStack-path race. A Close button dismisses back
//  to the exact tab + scroll position the DJ left. The detail's analytics
//  origin follows the link's source (issue #185).
//
//  Created by Jake on 6/23/26.
//  Copyright © 2026 WXYC. All rights reserved.
//

import SwiftUI

struct DeepLinkAlbumCover: View {
    let deepLink: PresentedDeepLink
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            AlbumDetailView(
                albumId: deepLink.route.id,
                fallback: deepLink.route.fallback,
                origin: AlbumDetailOrigin(deepLink.source)
            )
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Close") { dismiss() }
                }
            }
        }
    }
}
