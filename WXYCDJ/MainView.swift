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
//  Issue #151 (ADR 0008 Amendment 6): a terminal mid-playback failure now
//  persists this bar in a failed state instead of letting it vanish -- see
//  `PlaybackController.lastFailure` and `MiniPlayerBar` below.
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
            //
            // Issue #151: `lastFailure != nil` is the other half of the
            // gate, so a terminal failure keeps this bar on screen in its
            // failed state rather than letting it disappear along with
            // `currentItem` -- see ADR 0008 Amendment 6. The two conditions
            // are mutually exclusive in practice (`fail(_:)` always empties
            // a non-empty queue before setting `lastFailure`), so
            // `MiniPlayerBar` never has to reconcile both being true at once.
            if playback.currentItem != nil || playback.lastFailure != nil {
                MiniPlayerBar()
            }
        }
    }
}

/// The digital-archive transport strip: title/artist, play-pause, next --
/// or, once a terminal failure lands (issue #151), a dismissible failure
/// note in its place. `PlaybackController.lastFailure` and `currentItem`
/// are mutually exclusive (see `MainView.body`'s gate), so exactly one of
/// `failedBar`/`transportBar` renders at a time.
private struct MiniPlayerBar: View {
    @Environment(PlaybackController.self) private var playback

    var body: some View {
        if let record = playback.lastFailure {
            failedBar(record)
        } else {
            transportBar
        }
    }

    /// ADR 0008 Amendment 6's chosen surface for a terminal mid-playback
    /// failure. Dismissible rather than self-clearing --
    /// `lastFailure` is cleared at only three points (a fresh
    /// `playback.start(...)`, `stop()`, and this control), and neither of the
    /// first two happens by simply reading the message, so without a dismiss
    /// control this bar would occupy the bottom of every tab until the DJ
    /// tried to play something else or signed out.
    private func failedBar(_ record: PlaybackFailureRecord) -> some View {
        HStack(spacing: 12) {
            Image(systemName: "exclamationmark.triangle")
                .foregroundStyle(.secondary)
            // The album is named above the message, not folded into it: this
            // bar spans every tab, and the copy says "this album". Without a
            // referent on screen that phrase resolves against whichever detail
            // screen the DJ walked back to -- which, since `fail(_:)` tears
            // down whatever *was* playing, is routinely a different album than
            // the one that failed. Naming it is what makes the sentence true.
            VStack(alignment: .leading, spacing: 1) {
                if let albumTitle = record.albumTitle {
                    Text(albumTitle)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Text(PlaybackFailureCopy.message(for: record.failure))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(3)
                    // Grow rather than truncate: the longest case's copy is
                    // near the two-line boundary at this width before Dynamic
                    // Type is considered, and it is the case whose whole point
                    // is reading differently from `.emptyManifest`.
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
            Button {
                playback.dismissFailure()
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(.bar)
    }

    private var transportBar: some View {
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
