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
import os
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

    /// Catches: `case .newDeviceAvailable:` no longer resuming at all -- the
    /// `try? context?.play(…)` call being dropped, or its reason changing.
    /// It deliberately does **not** catch the `wasPlayingBeforeRouteDisconnect`
    /// guard being dropped: it sets the flag and asserts a resume happens, so
    /// removing the guard leaves it green. That mutation is the sibling
    /// test's, below.
    @Test("newDeviceAvailable resumes when wasPlayingBeforeRouteDisconnect is set")
    func newDeviceAvailableResumesWhenFlagged() {
        let fixture = Fixture()
        _ = fixture.handler
        fixture.wasPlayingBeforeRouteDisconnect = true

        fixture.postRouteChange(reason: .newDeviceAvailable)

        #expect(fixture.playCalls == [.resumeAfterRouteReconnect])
    }

    /// Catches: dropping the `if context?.wasPlayingBeforeRouteDisconnect ??
    /// false` guard in `case .newDeviceAvailable:`, i.e. resuming on every
    /// route reconnect even when nothing was playing before the disconnect.
    /// This is the only test in the file that catches that mutation.
    @Test("newDeviceAvailable does not resume when the flag is unset")
    func newDeviceAvailableDoesNotResumeWhenUnflagged() {
        let fixture = Fixture()
        _ = fixture.handler
        fixture.wasPlayingBeforeRouteDisconnect = false

        fixture.postRouteChange(reason: .newDeviceAvailable)

        #expect(fixture.playCalls.isEmpty)
    }

    /// Catches: deleting `deinit`, or either of its two `removeObserver`
    /// lines.
    ///
    /// It asserts on the **registration** rather than on delivery, because
    /// delivery cannot see this mutation: both observer blocks capture
    /// `[weak self]`, so after dealloc a still-registered block fires, finds
    /// `self?` nil, and calls nothing -- leaving `tearDownCalls` exactly as a
    /// delivery-based assertion expects. (The previous version of this test
    /// asserted delivery and passed with the entire `deinit` deleted.) A
    /// `NotificationCenter` subclass counts `removeObserver(_:)` calls
    /// instead, so a missing teardown is directly observable.
    @Test("deallocating the handler removes both of its observer registrations")
    func deallocatingRemovesObservers() {
        let center = RemoveObserverCountingNotificationCenter()
        let context = Fixture()
        var localHandler: PlaybackInterruptionRouteHandler? = PlaybackInterruptionRouteHandler(
            notificationCenter: center,
            context: context
        )
        _ = localHandler
        #expect(center.removeObserverCallCount == 0, "Nothing is removed while the handler is alive")

        localHandler = nil

        #expect(center.removeObserverCallCount == 2, "Both the interruption and route-change observers are removed")
    }
}

/// Counts single-argument `removeObserver(_:)` calls so a test can assert that
/// `PlaybackInterruptionRouteHandler.deinit` actually unregisters — see
/// `deallocatingRemovesObservers`. Lock-guarded rather than relying on
/// `NotificationCenter`'s inherited `Sendable` conformance, matching
/// `SpyErrorReporter`/`SpyAnalytics`.
private final class RemoveObserverCountingNotificationCenter: NotificationCenter {
    private let removals = OSAllocatedUnfairLock(initialState: 0)

    var removeObserverCallCount: Int { removals.withLock { $0 } }

    override func removeObserver(_ observer: Any) {
        removals.withLock { $0 += 1 }
        super.removeObserver(observer)
    }
}
