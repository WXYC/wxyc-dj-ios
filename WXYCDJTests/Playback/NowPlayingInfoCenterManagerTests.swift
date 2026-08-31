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

/// Spy that counts reads of the `nowPlayingInfo` getter. `NowPlayingInfoCenterManager`
/// must never read it on the main thread; `storedInfo` exposes the last
/// written value so a test can assert the result without inflating
/// `getterReadCount` itself.
@MainActor
private final class GetterCountingNowPlayingInfoCenter: NowPlayingInfoCenterProtocol {
    private(set) var getterReadCount = 0
    private(set) var storedInfo: [String: Any]?

    var nowPlayingInfo: [String: Any]? {
        get {
            getterReadCount += 1
            return storedInfo
        }
        set { storedInfo = newValue }
    }

    var playbackState: MPNowPlayingPlaybackState = .unknown
}

@MainActor
struct NowPlayingInfoCenterManagerTests {
    /// Catches: `setPlaybackState` no longer writing the playback rate, or
    /// swapping `.playing`/`.paused`.
    @Test("setPlaybackState writes the playback rate and infoCenter.playbackState")
    func setPlaybackStateWritesRateAndState() {
        let infoCenter = GetterCountingNowPlayingInfoCenter()
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
        let infoCenter = GetterCountingNowPlayingInfoCenter()
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
        let infoCenter = GetterCountingNowPlayingInfoCenter()
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
        let infoCenter = GetterCountingNowPlayingInfoCenter()
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
        let infoCenter = GetterCountingNowPlayingInfoCenter()
        let manager = NowPlayingInfoCenterManager(infoCenter: infoCenter)
        manager.updatePlaybackPosition(elapsed: 12, duration: 200)
        #expect(infoCenter.storedInfo?[MPNowPlayingInfoPropertyIsLiveStream] as? Bool == false)

        manager.clearPlaybackPosition()

        #expect(infoCenter.storedInfo?[MPNowPlayingInfoPropertyIsLiveStream] == nil)
    }

    /// Catches: `clearPlaybackPosition` dropping its `guard var info = cachedInfo`
    /// early return, which would write a bare `[isLiveStream: true]` dictionary
    /// (destroying anything else on screen) instead of no-op'ing.
    @Test("clearPlaybackPosition is a no-op when nothing has been written yet")
    func clearPlaybackPositionNoOpWhenNothingCached() {
        let infoCenter = GetterCountingNowPlayingInfoCenter()
        let manager = NowPlayingInfoCenterManager(infoCenter: infoCenter)

        manager.clearPlaybackPosition()

        #expect(infoCenter.storedInfo == nil)
    }

    /// Catches: any mutation that reads `infoCenter.nowPlayingInfo` back
    /// instead of the local mirror -- the exact XPC-hang regression this
    /// manager exists to prevent (Sentry IOS-3P).
    @Test("no method ever reads the nowPlayingInfo getter")
    func neverReadsGetter() {
        let infoCenter = GetterCountingNowPlayingInfoCenter()
        let manager = NowPlayingInfoCenterManager(infoCenter: infoCenter)

        manager.setPlaybackState(isPlaying: true)
        manager.updatePlaybackPosition(elapsed: 1, duration: 2)
        manager.clearPlaybackPosition()

        #expect(infoCenter.getterReadCount == 0)
    }
}
