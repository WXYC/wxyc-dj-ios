//
//  FakeAudioSession.swift
//  WXYCDJTests
//
//  An AudioSessionProtocol double for AudioSessionCoordinatorTests (issue
//  #137). Records every call so tests can assert on them, and can be told to
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

    private struct State {
        var categoryCalls: [CategoryCall] = []
        var activateCallCount = 0
        var deactivateCallCount = 0
        var pendingActivateError: (any Error)?
        var persistActivateError = false
        var deactivationsHeld = false
        var isBlockingOnHold = false
    }

    private let state = OSAllocatedUnfairLock(initialState: State())
    private let deactivationGate = DispatchSemaphore(value: 0)

    var categoryCalls: [CategoryCall] { state.withLock { $0.categoryCalls } }
    var activateCallCount: Int { state.withLock { $0.activateCallCount } }
    var deactivateCallCount: Int { state.withLock { $0.deactivateCallCount } }

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
            let error = state.withLock { st -> (any Error)? in
                st.activateCallCount += 1
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
            state.withLock { $0.deactivateCallCount += 1 }
        }
    }
}
