//
//  FakeAudioSession.swift
//  WXYCDJTests
//
//  An AudioSessionProtocol double for AudioSessionCoordinatorTests (issue
//  #137). Records every call -- including the options each one carried, since
//  `.notifyOthersOnDeactivation` is the single most user-visible property of
//  the handback path and the one an extraction is most likely to drop
//  silently -- so tests can assert on them, and can be told to
//  fail the next (or every) setActive(true, …) call to model a
//  CannotInterruptOthers failure. holdDeactivations()/releaseDeactivations()
//  block a setActive(false, …) call on a real DispatchSemaphore -- deliberate,
//  not a scripted throw: AudioSessionCoordinator's "self-handback in
//  progress" failure comes from its own sessionLock finding a deactivation
//  already holding it, so the only faithful way to exercise that path is
//  genuine contention on a real background thread, exactly as
//  deactivateLocked(ifGenerationIs:) runs it in production. Lock-guarded,
//  matching SpyBinStore/SpyErrorReporter: OSAllocatedUnfairLock is
//  unconditionally Sendable regardless of what it guards.
//
//  Created by Jake Bromberg on 08/29/26.
//  Copyright © 2026 WXYC. All rights reserved.
//

import AVFoundation
import os
@testable import WXYCDJ

final class FakeAudioSession: AudioSessionProtocol, @unchecked Sendable {
    struct CategoryCall: Equatable {
        let category: AVAudioSession.Category
        let mode: AVAudioSession.Mode
        let policy: AVAudioSession.RouteSharingPolicy
        let options: AVAudioSession.CategoryOptions
    }

    /// One `setActive` call, options included.
    struct SetActiveCall: Equatable {
        let active: Bool
        let options: AVAudioSession.SetActiveOptions
    }

    private struct State {
        var categoryCalls: [CategoryCall] = []
        var setActiveCalls: [SetActiveCall] = []
        var pendingActivateError: (any Error)?
        var persistActivateError = false
        var pendingDeactivateError: (any Error)?
        var deactivationsHeld = false
        var isBlockingOnHold = false
    }

    private let state = OSAllocatedUnfairLock(initialState: State())
    private let deactivationGate = DispatchSemaphore(value: 0)

    var categoryCalls: [CategoryCall] { state.withLock { $0.categoryCalls } }

    /// Every `setActive` call in order, so a test can pin the options as well
    /// as the count. Both counters below are derived from it rather than
    /// tracked alongside it, so they can't drift apart from what was
    /// recorded.
    var setActiveCalls: [SetActiveCall] { state.withLock { $0.setActiveCalls } }
    var activateCallCount: Int { setActiveCalls.filter(\.active).count }
    var deactivateCallCount: Int { setActiveCalls.filter { !$0.active }.count }

    /// Whether a `setActive(false, …)` call is currently parked on
    /// `deactivationGate`, waiting for `releaseDeactivations()`. A test polls
    /// this to know the held deactivation has genuinely started -- and is
    /// genuinely holding `AudioSessionCoordinator.sessionLock` -- before
    /// exercising the busy path.
    var isBlockingOnHold: Bool { state.withLock { $0.isBlockingOnHold } }

    /// The next `setActive(true, …)` call throws `error`, then reverts to
    /// succeeding.
    func failNextActivation(with error: any Error) {
        state.withLock { st in
            st.pendingActivateError = error
            st.persistActivateError = false
        }
    }

    /// Every `setActive(true, …)` call throws `error`, until
    /// `stopFailingActivations()` is called.
    func failAllActivations(with error: any Error) {
        state.withLock { st in
            st.pendingActivateError = error
            st.persistActivateError = true
        }
    }

    func stopFailingActivations() {
        state.withLock { st in
            st.pendingActivateError = nil
            st.persistActivateError = false
        }
    }

    /// The next `setActive(false, ...)` call throws `error`, then reverts to
    /// succeeding -- `mediaserverd` refusing a handback. There is no
    /// persistent variant on purpose: `AudioSessionCoordinator` leaves
    /// `isActivated` set on a failed handback precisely so the *next*
    /// `deactivate()` retries, and a permanently failing session would
    /// measure nothing but that retry never terminating.
    func failNextDeactivation(with error: any Error) {
        state.withLock { $0.pendingDeactivateError = error }
    }

    /// Blocks the *next* `setActive(false, …)` call until
    /// `releaseDeactivations()` is called, so a test can prove
    /// `AudioSessionCoordinator` sees a genuinely in-flight handback rather
    /// than a scripted result.
    func holdDeactivations() {
        state.withLock { $0.deactivationsHeld = true }
    }

    func releaseDeactivations() {
        state.withLock { $0.deactivationsHeld = false }
        deactivationGate.signal()
    }

    /// An `NSError` matching FourCC `'!int'` = `AVAudioSessionErrorCodeCannotInterruptOthers`.
    static func cannotInterruptOthersError() -> NSError {
        NSError(domain: "com.apple.coreaudio.avfaudio", code: 560_557_684)
    }

    // MARK: AudioSessionProtocol

    func setCategory(
        _ category: AVAudioSession.Category,
        mode: AVAudioSession.Mode,
        policy: AVAudioSession.RouteSharingPolicy,
        options: AVAudioSession.CategoryOptions
    ) throws {
        state.withLock {
            $0.categoryCalls.append(CategoryCall(category: category, mode: mode, policy: policy, options: options))
        }
    }

    func setActive(_ active: Bool, options: AVAudioSession.SetActiveOptions) throws {
        if active {
            // Recorded before the throw, so a failed activation still counts
            // as an attempt -- which is what the bounded-retry budget test
            // measures.
            let error = state.withLock { st -> (any Error)? in
                st.setActiveCalls.append(SetActiveCall(active: true, options: options))
                let error = st.pendingActivateError
                if !st.persistActivateError {
                    st.pendingActivateError = nil
                }
                return error
            }
            if let error {
                throw error
            }
        } else {
            let shouldHold = state.withLock { st -> Bool in
                if st.deactivationsHeld {
                    st.isBlockingOnHold = true
                    return true
                }
                return false
            }
            if shouldHold {
                deactivationGate.wait()
                state.withLock { $0.isBlockingOnHold = false }
            }
            // Recorded before the throw, for the same reason the activation
            // branch records first: a refused handback is still an attempt,
            // and the retry tests count attempts.
            let error = state.withLock { st -> (any Error)? in
                st.setActiveCalls.append(SetActiveCall(active: false, options: options))
                let error = st.pendingDeactivateError
                st.pendingDeactivateError = nil
                return error
            }
            if let error {
                throw error
            }
        }
    }
}
