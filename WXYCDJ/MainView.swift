//
//  MainView.swift
//  WXYCDJ
//
//  Two-tab shell for the signed-in DJ: Search and Bin. Sign-out lives in
//  the navigation toolbar of each tab. Issue #145 adds the digital-archive
//  mini-player as a `.safeAreaInset(edge: .bottom)` on the `TabView`, so it
//  stays reachable from either tab. Deliberately **not** hosted inside the
//  Spotlight deep-link `fullScreenCover` (`DeepLinkAlbumCover.swift`) -- that
//  presentation is a separate context this view has no part in, and wiring
//  the mini-player into it is a follow-up, not this ticket's scope.
//
//  Created by Jake on 5/14/26.
//  Copyright © 2026 WXYC. All rights reserved.
//

import SwiftUI
import WXYCAPI

struct MainView: View {
    @Environment(AuthService.self) private var auth
    @Environment(PlaybackController.self) private var playback

    var body: some View {
        TabView {
            Tab("Search", systemImage: "magnifyingglass") {
                NavigationStack { SearchView() }
            }
            Tab("Bin", systemImage: "tray") {
                NavigationStack { BinView() }
            }
        }
        .safeAreaInset(edge: .bottom) {
            // `currentItem`, not `queue.isEmpty`: the queue array itself
            // isn't cleared when playback runs off the end naturally
            // (only `stop()`/a terminal `fail(_:)` clear it via
            // `clearQueue()`), so gating on emptiness alone would leave a
            // stale mini-player showing after an album finished playing.
            // `currentIndex == nil` -- and so `currentItem == nil` -- covers
            // every case the queue being genuinely empty does, plus that one.
            if playback.currentItem != nil {
                MiniPlayerBar()
            }
        }
    }
}

/// The digital-archive transport strip: title/artist, play-pause, next.
private struct MiniPlayerBar: View {
    @Environment(PlaybackController.self) private var playback

    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(playback.currentItem?.title ?? "")
                    .font(.subheadline.bold())
                    .lineLimit(1)
                Text(playback.currentItem?.artistName ?? "")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer()
            Button {
                playback.togglePlayPause()
            } label: {
                // Renders `isPlaybackRequested`, not `isPlaying` -- the same
                // requested-vs-actual split `togglePlayPause()` itself
                // branches on, so a tap during a slow connect still shows
                // "pause" (what the DJ just asked for) instead of "play"
                // inviting a second tap that would re-issue the start.
                Image(systemName: playback.isPlaybackRequested ? "pause.fill" : "play.fill")
                    .font(.title2)
                    .frame(width: 28, height: 28)
            }
            .buttonStyle(.plain)
            Button {
                playback.advance()
            } label: {
                Image(systemName: "forward.fill")
                    .font(.title2)
                    .frame(width: 28, height: 28)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(.bar)
    }
}
