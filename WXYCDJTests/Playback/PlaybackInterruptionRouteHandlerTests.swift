//
//  PlaybackInterruptionRouteHandlerTests.swift
//  WXYCDJTests
//
//  Direct unit tests for the ported PlaybackInterruptionRouteHandler (issue
//  #138): the pure interruption/route-change decisions, exercised through
//  real AVAudioSession notifications posted on a private NotificationCenter
//  so no other test or the app itself can interfere. Each test's doc comment
//  states the single-line production mutation it would catch, per the
//  issue's acceptance criteria.
//
//  Created by Jake Bromberg on 08/30/26.
//  Copyright © 2026 WXYC. All rights reserved.
//

import AVFoundation
import Testing
@testable import WXYCDJ

@MainActor
struct PlaybackInterruptionRouteHandlerTests {
    /// Records every `tearDown`/`play` call and lets a test drive `isPlaying`
    /// / `wasPlayingBeforeRouteDisconnect` as controllable state, mirroring
    /// how a real `PlaybackController` (issue #144) will conform.
    @MainActor
    private final class Fixture: PlaybackInterruptionContext {
        let notificationCenter = NotificationCenter()

        var isPlaying = false
        var wasPlayingBeforeRouteDisconnect = false

        private(set) var tearDownCalls: [PlaybackReason] = []
        private(set) var playCalls: [PlaybackReason] = []

        func tearDown(reason: PlaybackReason) { tearDownCalls.append(reason) }
        func play(reason: PlaybackReason) throws { playCalls.append(reason) }

        lazy var handler = PlaybackInterruptionRouteHandler(
            notificationCenter: notificationCenter,
            context: self
        )

        func postInterruption(type: AVAudioSession.InterruptionType, options: AVAudioSession.InterruptionOptions = []) {
            notificationCenter.post(
                name: AVAudioSession.interruptionNotification,
                object: nil,
                userInfo: [
                    AVAudioSessionInterruptionTypeKey: type.rawValue,
                    AVAudioSessionInterruptionOptionKey: options.rawValue,
                ]
            )
        }

        func postRouteChange(reason: AVAudioSession.RouteChangeReason) {
            notificationCenter.post(
                name: AVAudioSession.routeChangeNotification,
                object: nil,
                userInfo: [AVAudioSessionRouteChangeReasonKey: reason.rawValue]
            )
        }
    }

    /// Catches: `case .began:` no longer tearing down while playing (e.g. the
    /// guard is inverted, or dropped, or the reason changes).
    @Test("interruption began while playing pauses")
    func interruptionBeganWhilePlayingPauses() {
        let fixture = Fixture()
        _ = fixture.handler
        fixture.isPlaying = true

        fixture.postInterruption(type: .began)

        #expect(fixture.tearDownCalls == [.interruptionBegan])
    }

    /// Catches: `case .began:` tearing down even while `isPlaying` is false.
    @Test("interruption began while not playing does not pause")
    func interruptionBeganWhileNotPlayingIsNoOp() {
        let fixture = Fixture()
        _ = fixture.handler
        fixture.isPlaying = false

        fixture.postInterruption(type: .began)

        #expect(fixture.tearDownCalls.isEmpty)
    }

    /// Catches: `options.contains(.shouldResume) && wasPlayingBeforeInterruption`
    /// losing either half of that conjunction, or the resume reason changing.
    @Test("interruption ended with shouldResume, after a began-while-playing, resumes")
    func interruptionEndedWithShouldResumeResumes() {
        let fixture = Fixture()
        _ = fixture.handler
        fixture.isPlaying = true
        fixture.postInterruption(type: .began)

        fixture.postInterruption(type: .ended, options: .shouldResume)

        #expect(fixture.playCalls == [.resumeAfterInterruption])
    }

    /// Catches: dropping the `options.contains(.shouldResume)` check, i.e.
    /// resuming on every `.ended` regardless of the option.
    @Test("interruption ended without shouldResume does not resume")
    func interruptionEndedWithoutShouldResumeDoesNotResume() {
        let fixture = Fixture()
        _ = fixture.handler
        fixture.isPlaying = true
        fixture.postInterruption(type: .began)

        fixture.postInterruption(type: .ended, options: [])

        #expect(fixture.playCalls.isEmpty)
    }

    /// Catches: `wasPlayingBeforeInterruption` never being cleared, which
    /// would let a second, redundant `.ended` resume again.
    @Test("wasPlayingBeforeInterruption is cleared after ended, so a second ended does not resume again")
    func wasPlayingBeforeInterruptionClearedAfterEnded() {
        let fixture = Fixture()
        _ = fixture.handler
        fixture.isPlaying = true
        fixture.postInterruption(type: .began)
        fixture.postInterruption(type: .ended, options: .shouldResume)
        #expect(fixture.playCalls == [.resumeAfterInterruption])

        fixture.postInterruption(type: .ended, options: .shouldResume)

        #expect(fixture.playCalls == [.resumeAfterInterruption])
    }

    /// Catches: `cancelPendingInterruptionResume()` not clearing
    /// `wasPlayingBeforeInterruption` -- without it, pausing from the Lock
    /// Screen during a call would restart playback when the call ends.
    @Test("a cancelled pending resume does not fire")
    func cancelledPendingResumeDoesNotFire() {
        let fixture = Fixture()
        _ = fixture.handler
        fixture.isPlaying = true
        fixture.postInterruption(type: .began)

        fixture.handler.cancelPendingInterruptionResume()
        fixture.postInterruption(type: .ended, options: .shouldResume)

        #expect(fixture.playCalls.isEmpty)
    }

    /// Catches: `case .oldDeviceUnavailable:` no longer tearing down while
    /// playing, or no longer recording `wasPlayingBeforeRouteDisconnect`.
    @Test("oldDeviceUnavailable while playing pauses and records wasPlayingBeforeRouteDisconnect")
    func oldDeviceUnavailableWhilePlayingPauses() {
        let fixture = Fixture()
        _ = fixture.handler
        fixture.isPlaying = true

        fixture.postRouteChange(reason: .oldDeviceUnavailable)

        #expect(fixture.tearDownCalls == [.routeDisconnected])
        #expect(fixture.wasPlayingBeforeRouteDisconnect == true)
    }

    /// Catches: `oldDeviceUnavailable` tearing down even while not playing.
    @Test("oldDeviceUnavailable while not playing does not pause")
    func oldDeviceUnavailableWhileNotPlayingIsSafe() {
        let fixture = Fixture()
        _ = fixture.handler
        fixture.wasPlayingBeforeRouteDisconnect = true
        fixture.isPlaying = false

        fixture.postRouteChange(reason: .oldDeviceUnavailable)

        #expect(fixture.tearDownCalls.isEmpty)
        #expect(fixture.wasPlayingBeforeRouteDisconnect == false)
    }

    /// Catches: `newDeviceAvailable` resuming even when nothing was playing
    /// before the disconnect.
    @Test("newDeviceAvailable resumes only when wasPlayingBeforeRouteDisconnect is set")
    func newDeviceAvailableResumesWhenFlagged() {
        let fixture = Fixture()
        _ = fixture.handler
        fixture.wasPlayingBeforeRouteDisconnect = true

        fixture.postRouteChange(reason: .newDeviceAvailable)

        #expect(fixture.playCalls == [.resumeAfterRouteReconnect])
    }

    @Test("newDeviceAvailable does not resume when the flag is unset")
    func newDeviceAvailableDoesNotResumeWhenUnflagged() {
        let fixture = Fixture()
        _ = fixture.handler
        fixture.wasPlayingBeforeRouteDisconnect = false

        fixture.postRouteChange(reason: .newDeviceAvailable)

        #expect(fixture.playCalls.isEmpty)
    }

    /// Catches: deallocating the handler without removing its observers,
    /// which would deliver notifications to a deallocated instance forever.
    @Test("deallocating the handler stops delivering notifications")
    func deallocatingRemovesObservers() {
        let center = NotificationCenter()
        let context = Fixture()
        var localHandler: PlaybackInterruptionRouteHandler? = PlaybackInterruptionRouteHandler(
            notificationCenter: center,
            context: context
        )
        _ = localHandler
        context.isPlaying = true

        center.post(
            name: AVAudioSession.interruptionNotification,
            object: nil,
            userInfo: [
                AVAudioSessionInterruptionTypeKey: AVAudioSession.InterruptionType.began.rawValue,
                AVAudioSessionInterruptionOptionKey: UInt(0),
            ]
        )
        #expect(context.tearDownCalls == [.interruptionBegan])

        localHandler = nil

        center.post(
            name: AVAudioSession.interruptionNotification,
            object: nil,
            userInfo: [
                AVAudioSessionInterruptionTypeKey: AVAudioSession.InterruptionType.began.rawValue,
                AVAudioSessionInterruptionOptionKey: UInt(0),
            ]
        )
        #expect(context.tearDownCalls == [.interruptionBegan], "No further delivery once the handler is deallocated")
    }
}
