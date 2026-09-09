//
//  NowPlayingInfoCenterManagerTests.swift
//  WXYCDJTests
//
//  Unit tests for the ported NowPlayingInfoCenterManager (issue #138): the
//  playback-state and position writes, and the local-mirror discipline that
//  exists specifically so `MPNowPlayingInfoCenter.nowPlayingInfo` is never
//  read back (Sentry IOS-3P AppHang). Each test's doc comment states the
//  single-line production mutation it would catch.
//
//  Created by Jake Bromberg on 08/30/26.
//  Copyright © 2026 WXYC. All rights reserved.
//

import MediaPlayer
import Testing
@testable import WXYCDJ

@MainActor
struct NowPlayingInfoCenterManagerTests {
    /// Catches: `setPlaybackState` no longer writing the playback rate, or
    /// swapping `.playing`/`.paused`.
    @Test("setPlaybackState writes the playback rate and infoCenter.playbackState")
    func setPlaybackStateWritesRateAndState() {
        let infoCenter = SpyNowPlayingInfoCenter()
        let manager = NowPlayingInfoCenterManager(infoCenter: infoCenter)

        manager.setPlaybackState(isPlaying: true)
        #expect(infoCenter.storedInfo?[MPNowPlayingInfoPropertyPlaybackRate] as? Double == 1.0)
        #expect(infoCenter.playbackState == .playing)

        manager.setPlaybackState(isPlaying: false)
        #expect(infoCenter.storedInfo?[MPNowPlayingInfoPropertyPlaybackRate] as? Double == 0.0)
        #expect(infoCenter.playbackState == .paused)
    }

    /// Catches: `updatePlaybackPosition` no longer setting `isLiveStream` to
    /// `false`, which would suppress the Lock Screen scrub bar.
    @Test("updatePlaybackPosition writes elapsed, duration, rate, and disables live-stream mode")
    func updatePlaybackPositionWritesFields() {
        let infoCenter = SpyNowPlayingInfoCenter()
        let manager = NowPlayingInfoCenterManager(infoCenter: infoCenter)
        manager.setPlaybackState(isPlaying: true)

        manager.updatePlaybackPosition(elapsed: 12, duration: 200)

        #expect(infoCenter.storedInfo?[MPMediaItemPropertyPlaybackDuration] as? Double == 200)
        #expect(infoCenter.storedInfo?[MPNowPlayingInfoPropertyElapsedPlaybackTime] as? Double == 12)
        #expect(infoCenter.storedInfo?[MPNowPlayingInfoPropertyPlaybackRate] as? Double == 1.0)
        #expect(infoCenter.storedInfo?[MPNowPlayingInfoPropertyIsLiveStream] as? Bool == false)
    }

    /// Catches: restoring the source's live-radio assumption, i.e. reverting
    /// `updatePlaybackPosition`'s rate write to the unconditional
    /// `info[MPNowPlayingInfoPropertyPlaybackRate] = 1.0`. That single line is
    /// what would let a periodic time observer (WXYC/wxyc-dj-ios#145) advance
    /// the Lock Screen scrub bar against a player the DJ has paused.
    @Test("a position update after a pause restates the paused rate rather than asserting 1.0")
    func positionUpdateAfterPauseKeepsTheRateAtZero() {
        let infoCenter = SpyNowPlayingInfoCenter()
        let manager = NowPlayingInfoCenterManager(infoCenter: infoCenter)
        manager.setPlaybackState(isPlaying: true)
        manager.updatePlaybackPosition(elapsed: 12, duration: 200)

        manager.setPlaybackState(isPlaying: false)
        manager.updatePlaybackPosition(elapsed: 13, duration: 200)

        #expect(infoCenter.storedInfo?[MPNowPlayingInfoPropertyPlaybackRate] as? Double == 0.0)
        #expect(infoCenter.playbackState == .paused)
        #expect(infoCenter.storedInfo?[MPNowPlayingInfoPropertyElapsedPlaybackTime] as? Double == 13)
    }

    /// Catches: `clearPlaybackPosition` no longer removing the duration/elapsed
    /// keys, which would leave a stale scrub bar position on screen.
    @Test("clearPlaybackPosition removes the position keys")
    func clearPlaybackPositionResetsFields() {
        let infoCenter = SpyNowPlayingInfoCenter()
        let manager = NowPlayingInfoCenterManager(infoCenter: infoCenter)
        manager.updatePlaybackPosition(elapsed: 12, duration: 200)

        manager.clearPlaybackPosition()

        #expect(infoCenter.storedInfo?[MPMediaItemPropertyPlaybackDuration] == nil)
        #expect(infoCenter.storedInfo?[MPNowPlayingInfoPropertyElapsedPlaybackTime] == nil)
    }

    /// Catches: restoring the source's other live-radio assumption, i.e.
    /// reinstating `info[MPNowPlayingInfoPropertyIsLiveStream] = true` in
    /// `clearPlaybackPosition`. This app is archive-only (ADR 0008), so the
    /// only method that can clear a position must not assert the app is
    /// playing a live stream; the key is removed, not set.
    @Test("clearPlaybackPosition never asserts live-stream mode")
    func clearPlaybackPositionDoesNotAssertLiveStream() {
        let infoCenter = SpyNowPlayingInfoCenter()
        let manager = NowPlayingInfoCenterManager(infoCenter: infoCenter)
        manager.updatePlaybackPosition(elapsed: 12, duration: 200)
        #expect(infoCenter.storedInfo?[MPNowPlayingInfoPropertyIsLiveStream] as? Bool == false)

        manager.clearPlaybackPosition()

        #expect(infoCenter.storedInfo?[MPNowPlayingInfoPropertyIsLiveStream] == nil)
    }

    /// Catches: `clearPlaybackPosition` dropping its `guard var info = cachedInfo`
    /// early return, which would commit a bare `[:]` dictionary — destroying
    /// anything else on screen — instead of no-op'ing. (Before the review fix
    /// that stopped this method asserting `isLiveStream`, the mutation wrote
    /// `[isLiveStream: true]`; the assertion is unchanged either way, since it
    /// pins that nothing at all was committed.)
    @Test("clearPlaybackPosition is a no-op when nothing has been written yet")
    func clearPlaybackPositionNoOpWhenNothingCached() {
        let infoCenter = SpyNowPlayingInfoCenter()
        let manager = NowPlayingInfoCenterManager(infoCenter: infoCenter)

        manager.clearPlaybackPosition()

        #expect(infoCenter.storedInfo == nil)
    }

    /// Catches: dropping any one of the three key writes in
    /// `setNowPlayingItem(title:artistName:albumTitle:)` — each is the single
    /// line that puts one row of the Lock Screen card on screen.
    @Test("setNowPlayingItem writes title, artist, and album")
    func setNowPlayingItemWritesTheThreeMetadataKeys() {
        let infoCenter = SpyNowPlayingInfoCenter()
        let manager = NowPlayingInfoCenterManager(infoCenter: infoCenter)

        manager.setNowPlayingItem(title: "la paradoja", artistName: "Juana Molina", albumTitle: "DOGA")

        #expect(infoCenter.storedString(MPMediaItemPropertyTitle) == "la paradoja")
        #expect(infoCenter.storedString(MPMediaItemPropertyArtist) == "Juana Molina")
        #expect(infoCenter.storedString(MPMediaItemPropertyAlbumTitle) == "DOGA")
    }

    /// Catches: `setNowPlayingItem` committing a fresh dictionary rather than
    /// going through `mutate` — a track change would then wipe the playback
    /// rate `setPlaybackState` is the sole author of, leaving the Lock Screen
    /// with no rate under a `.playing` `playbackState`.
    @Test("a metadata write preserves the playback rate already published")
    func setNowPlayingItemPreservesTheRate() {
        let infoCenter = SpyNowPlayingInfoCenter()
        let manager = NowPlayingInfoCenterManager(infoCenter: infoCenter)
        manager.setPlaybackState(isPlaying: true)

        manager.setNowPlayingItem(title: "un día", artistName: "Juana Molina", albumTitle: "DOGA")

        #expect(infoCenter.storedInfo?[MPNowPlayingInfoPropertyPlaybackRate] as? Double == 1.0)
    }

    /// Catches: `clear()` clearing only the local mirror (or only the info
    /// centre) rather than both — a half-clear leaves either a stale card on
    /// the Lock Screen or a mirror that seeds the next write with the dead
    /// album's fields.
    @Test("clear() empties both the info centre and the mirror, and stops the card")
    func clearEmptiesEverything() {
        let infoCenter = SpyNowPlayingInfoCenter()
        let manager = NowPlayingInfoCenterManager(infoCenter: infoCenter)
        manager.setNowPlayingItem(title: "eras", artistName: "Juana Molina", albumTitle: "DOGA")
        manager.setPlaybackState(isPlaying: true)

        manager.clear()
        #expect(infoCenter.storedInfo == nil)
        #expect(infoCenter.playbackState == .stopped)

        // The mirror is empty too, so the next write starts from nothing
        // rather than resurrecting the cleared album's title.
        manager.setPlaybackState(isPlaying: false)
        #expect(infoCenter.storedString(MPMediaItemPropertyTitle) == nil)
    }

    /// Catches: `clear()` leaving `lastKnownIsPlaying` set, which would make
    /// the next `updatePlaybackPosition` publish a playing rate for an album
    /// nobody has started.
    @Test("clear() resets the remembered playback rate")
    func clearResetsTheRateMirror() {
        let infoCenter = SpyNowPlayingInfoCenter()
        let manager = NowPlayingInfoCenterManager(infoCenter: infoCenter)
        manager.setPlaybackState(isPlaying: true)

        manager.clear()
        manager.updatePlaybackPosition(elapsed: 0, duration: 100)

        #expect(infoCenter.storedInfo?[MPNowPlayingInfoPropertyPlaybackRate] as? Double == 0.0)
    }

    /// Catches: any mutation that reads `infoCenter.nowPlayingInfo` back
    /// instead of the local mirror -- the exact XPC-hang regression this
    /// manager exists to prevent (Sentry IOS-3P).
    @Test("no method ever reads the nowPlayingInfo getter")
    func neverReadsGetter() {
        let infoCenter = SpyNowPlayingInfoCenter()
        let manager = NowPlayingInfoCenterManager(infoCenter: infoCenter)

        manager.setPlaybackState(isPlaying: true)
        manager.setNowPlayingItem(title: "la paradoja", artistName: "Juana Molina", albumTitle: "DOGA")
        manager.updatePlaybackPosition(elapsed: 1, duration: 2)
        manager.clearPlaybackPosition()
        manager.clear()

        #expect(infoCenter.getterReadCount == 0)
    }
}
