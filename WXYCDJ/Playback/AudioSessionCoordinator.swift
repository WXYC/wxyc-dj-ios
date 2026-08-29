//
//  AudioSessionCoordinator.swift
//  WXYCDJ
//
//  Owns the three AVAudioSession behaviours wxyc-ios-64's AudioPlayerController
//  had to get right the hard way (issue #137), extracted on their own so a
//  future PlaybackEngine (issue #138) can depend on something small and
//  already reviewed rather than reinvent them. Nothing else rides along here:
//  no engine selection, no CPU aggregation, no render taps, no background-task
//  assertions -- see docs/adr/0008-archive-playback.md for what this
//  deliberately leaves behind and why.
//
//  Ported from wxyc-ios-64's
//  Shared/Playback/Sources/PlaybackAPI/AudioPlayerController.swift (c22a3eb),
//  the category/activation logic at ~lines 1038-1121 and the deferred
//  deactivation at ~lines 1558-1592.
//
//  Created by Jake Bromberg on 08/29/26.
//  Copyright © 2026 WXYC. All rights reserved.
//

import AVFoundation
import os

/// Configures, activates, and deactivates the app's `AVAudioSession`.
///
/// Three behaviours, each carried over from a specific field failure in the
/// listener app rather than invented here:
///
/// 1. **The category is set lazily, on the first `activate()`, never in
///    `init`.** Configuring it at init would interrupt whatever else is
///    already playing at app launch. `.default` route-sharing policy, not
///    `.longFormAudio` -- this coordinator serves short-form music, not the
///    long-form policy the source uses.
/// 2. **Activation distinguishes two failure modes that look identical from
///    the caller's side but need opposite handling.** A `CannotInterruptOthers`
///    (`'!int'`) failure means another app holds the session, and gets a
///    *bounded* retry (`maxRetryAttempts` tries, `retryDelay` apart). This
///    coordinator's own in-flight `deactivate()` throws a different, private
///    error instead: the handback it performs is a synchronous XPC round
///    trip measured at ~1s on device, which would exhaust the bounded budget
///    before the handback even finishes and strand playback
///    (wxyc-ios-64#514). That case sets `activationPending` and returns
///    `false` immediately, without spending any retry budget -- the
///    deactivation already in flight is what re-drives the activation, via
///    `resumeDeferredActivationAfterHandback()`, the moment it completes.
/// 3. **Deactivation runs off the main actor, under a generation counter.**
///    `setActive(false, …)` is a synchronous XPC round trip to `mediaserverd`
///    that measures ~1s on a real device (~1ms in the Simulator, which is
///    why this is easy to miss). Running it on the caller's turn would
///    freeze whatever UI is waiting on that turn to return. `Task.cancel()`
///    alone can't guard a concurrent `activate()`, because cancellation is
///    cooperative and may arrive after the XPC call has already started; a
///    generation counter, bumped only by a successful activation, lets a
///    deactivation scheduled before it recognize itself as stale and decline
///    rather than tearing down a session `activate()` already stood back up.
///
/// `@MainActor` except for the deactivation path itself, which is
/// `nonisolated` on purpose -- see `deactivateLocked(ifGenerationIs:)`. There
/// is deliberately no public resume method, no closure parameter on
/// `activate()`, and no `AsyncStream` on this seam: the handback resume is
/// this coordinator's own business, finished inline once the deactivation's
/// generation check has run.
@MainActor
final class AudioSessionCoordinator {
    /// Thrown by `activateLocked()` when this coordinator's own deactivation
    /// currently holds `sessionLock`. Not a session failure -- the caller
    /// defers instead of treating it as one (behaviour 2 above).
    private struct HandbackInProgress: Error {}

    /// A single attempt's outcome, so `activate()` and the bounded retry loop
    /// act on the same classification rather than re-deriving it.
    private enum ActivationAttempt {
        case activated
        case blockedBySelfHandback
        case blockedByOtherApp
        case failed
    }

    private static let avfaudioErrorDomain = "com.apple.coreaudio.avfaudio"
    /// FourCC `'!int'` = `AVAudioSessionErrorCodeCannotInterruptOthers`.
    private static let cannotInterruptOthersCode = 560_557_684

    private nonisolated(unsafe) let session: any AudioSessionProtocol
    private let maxRetryAttempts: Int
    private let retryDelay: Duration
    private let log = Logger(subsystem: "org.wxyc.dj", category: "playback")

    /// Set once, on the first successful pass through `configureCategoryIfNeeded()` -- see behaviour 1.
    private var categoryConfigured = false

    /// Whether the session is currently believed active. Cleared only once a
    /// deactivation is *confirmed* (the generation check in behaviour 3
    /// passed and the handback succeeded), never merely attempted.
    private(set) var isActivated = false

    /// Set while an activation is deferred behind either failure mode in
    /// behaviour 2, so the eventual retry or handback-resume knows there is
    /// something to finish.
    private(set) var activationPending = false

    /// The bounded retry loop for behaviour 2's `CannotInterruptOthers` case.
    private var retryTask: Task<Void, Never>?

    /// Counts only the bounded-retry loop's own attempts -- never the
    /// self-handback path. `activationRetryAttempts == 0` after a
    /// handback-driven resume is what proves that path never spent the
    /// budget behaviour 2 exists to protect.
    private(set) var activationRetryAttempts = 0

    /// Bumped once per `deactivate()` call, after its detached deactivation
    /// and any resulting resume have both finished. Exposed so tests can wait
    /// for a scheduled deactivation to fully settle instead of guessing a
    /// duration.
    private(set) var deactivationSettledCount = 0

    /// Serializes every `setActive` call against a deactivation this
    /// coordinator itself may have in flight. `activate()` only ever tries
    /// this lock (`lockIfAvailable()`); it never blocks the main actor on it
    /// -- see `HandbackInProgress`'s doc comment for why.
    private let sessionLock = OSAllocatedUnfairLock()

    /// Bumped only by a successful `activateLocked()`, which is main-actor
    /// isolated, so the main actor is the sole writer and may read it
    /// unlocked. The deactivation path reads it from off the actor, under
    /// `sessionLock`, which is what makes a stale read impossible.
    private nonisolated(unsafe) var activationGeneration = 0

    init(
        session: any AudioSessionProtocol,
        maxRetryAttempts: Int = 4,
        retryDelay: Duration = .milliseconds(250)
    ) {
        self.session = session
        self.maxRetryAttempts = maxRetryAttempts
        self.retryDelay = retryDelay
    }

    // MARK: - Activation

    /// Configures the category if needed, then activates the session.
    ///
    /// Synchronous and always returns promptly -- it never blocks waiting on
    /// the bounded retry ramp or on an in-flight handback (behaviour 2). A
    /// `false` return means the activation was deferred; it is retried
    /// automatically, either by the bounded retry loop or by the in-flight
    /// deactivation's completion.
    @discardableResult
    func activate() -> Bool {
        switch attemptActivation() {
        case .activated:
            activationPending = false
            cancelRetryTask()
            return true
        case .blockedBySelfHandback:
            log.info("Audio session still being handed back; deferring activation until it completes")
            activationPending = true
            return false
        case .blockedByOtherApp:
            scheduleRetry()
            return false
        case .failed:
            return false
        }
    }

    // MARK: - Deactivation

    /// Hands the session back to the system, off the caller's turn.
    ///
    /// A no-op if the session isn't currently believed active. Otherwise
    /// captures the generation it was activated under and performs the real
    /// `setActive(false, …)` on a detached task (behaviour 3). If `activate()`
    /// wins a race and reactivates before that task runs, the captured
    /// generation no longer matches by the time `deactivateLocked(ifGenerationIs:)`
    /// checks it, and the stale attempt declines rather than tearing down a
    /// session `activate()` just stood back up.
    func deactivate() {
        guard isActivated else { return }
        let generation = activationGeneration
        Task { [self] in
            let handedBack = await Task.detached(priority: .userInitiated) {
                self.deactivateLocked(ifGenerationIs: generation)
            }.value
            if handedBack, activationGeneration == generation {
                isActivated = false
            }
            // Coordinator-internal by design: there is no public resume, no
            // closure parameter on activate(), and no AsyncStream on the
            // seam. A deferred activation is finished here, inline, rather
            // than handed to a caller to orchestrate.
            resumeDeferredActivationAfterHandback()
            deactivationSettledCount += 1
        }
    }

    private func resumeDeferredActivationAfterHandback() {
        guard activationPending else { return }
        activationPending = false
        activate()
    }

    // MARK: - Internals

    private func attemptActivation() -> ActivationAttempt {
        configureCategoryIfNeeded()
        do {
            try activateLocked()
            isActivated = true
            return .activated
        } catch is HandbackInProgress {
            return .blockedBySelfHandback
        } catch {
            if isCannotInterruptOthers(error) {
                return .blockedByOtherApp
            }
            log.error("Failed to activate audio session: \(error)")
            return .failed
        }
    }

    /// Takes `sessionLock` only if it's free. An unavailable lock means a
    /// deferred deactivation is mid-`setActive(false, …)` -- the very XPC
    /// call this class exists to keep off the main actor. Blocking on it
    /// here would just relocate that freeze onto the activation path
    /// instead, so the caller defers to the bounded retry (or the handback's
    /// own completion) rather than waiting.
    private func activateLocked() throws {
        guard sessionLock.lockIfAvailable() else { throw HandbackInProgress() }
        defer { sessionLock.unlock() }
        try session.setActive(true, options: [])
        activationGeneration &+= 1
    }

    /// Performs the deactivation unless the session has been reactivated
    /// since it was scheduled. Runs entirely under `sessionLock`, so it can
    /// never interleave with a concurrent `activateLocked()`.
    private nonisolated func deactivateLocked(ifGenerationIs expected: Int) -> Bool {
        sessionLock.lock()
        defer { sessionLock.unlock() }
        guard activationGeneration == expected else { return false }
        do {
            try session.setActive(false, options: .notifyOthersOnDeactivation)
            return true
        } catch {
            return false
        }
    }

    private func configureCategoryIfNeeded() {
        guard !categoryConfigured else { return }
        categoryConfigured = true
        do {
            try session.setCategory(.playback, mode: .default, policy: .default, options: [])
        } catch {
            log.error("Failed to configure audio session category: \(error)")
        }
    }

    private func isCannotInterruptOthers(_ error: Error) -> Bool {
        let nsError = error as NSError
        return nsError.domain == Self.avfaudioErrorDomain
            && nsError.code == Self.cannotInterruptOthersCode
    }

    private func cancelRetryTask() {
        retryTask?.cancel()
        retryTask = nil
    }

    /// Schedules a bounded sequence of retries after a `CannotInterruptOthers`
    /// failure. Deliberately does not busy-loop: attempts are spaced
    /// `retryDelay` apart and stop after `maxRetryAttempts`.
    private func scheduleRetry() {
        guard !activationPending else { return }
        activationPending = true
        activationRetryAttempts = 0
        cancelRetryTask()
        log.info("Audio session activation blocked by another app; scheduling bounded retry")

        retryTask = Task { [weak self] in
            guard let self else { return }
            var attempt = 0
            while attempt < self.maxRetryAttempts {
                attempt += 1
                do {
                    try await Task.sleep(for: self.retryDelay)
                } catch {
                    return
                }
                guard !Task.isCancelled, self.activationPending else { return }
                self.activationRetryAttempts += 1
                switch self.attemptActivation() {
                case .activated:
                    self.activationPending = false
                    self.retryTask = nil
                    return
                case .blockedBySelfHandback:
                    // A handback started between attempts. Its own
                    // completion re-drives the activation now, via
                    // resumeDeferredActivationAfterHandback() -- this bounded
                    // loop has nothing further to add.
                    return
                case .blockedByOtherApp, .failed:
                    continue
                }
            }
            self.log.error("Audio session activation retries exhausted; giving up for this attempt")
            self.activationPending = false
            self.retryTask = nil
        }
    }
}
