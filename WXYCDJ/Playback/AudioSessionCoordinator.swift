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
//  Shared/Playback/Sources/PlaybackAPI/AudioPlayerController.swift (c22a3eb):
//  the category/activation logic at ~lines 1038-1121, the intent gating on
//  all three activation re-drive points at ~lines 1128, ~1149 and ~1452, the
//  scheduling and coalescing of a deferred deactivation at ~lines 1297-1362
//  with its drain at ~lines 1505-1510, and the deactivation itself -- outcome
//  carried out of the lock so it can be logged outside it -- at ~lines
//  1558-1592.
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
///    Both re-drive paths are gated on the caller's standing intent
///    (`activationIntended`), so a `deactivate()` arriving while an
///    activation is deferred cancels it rather than letting it stand a
///    `.playback` session back up after the caller asked for release.
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
///    A second `deactivate()` arriving inside that ~1s window does not stack
///    a second XPC call behind the first: it is recorded and re-driven once,
///    by the in-flight handback's own completion -- see
///    `deactivationInFlight`.
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

    /// What a deferred deactivation attempt did, carried back out of
    /// `sessionLock` so the logging that describes it doesn't happen while
    /// holding it.
    private enum DeactivationOutcome {
        case deactivated
        case failed(any Error)
        case stale
    }

    private static let avfaudioErrorDomain = "com.apple.coreaudio.avfaudio"
    /// FourCC `'!int'` (560557684) = `AVAudioSessionErrorCodeCannotInterruptOthers`.
    /// Read off the SDK symbol rather than spelled as a literal: this target
    /// is iOS-only and already imports AVFoundation, so the `#else` literal
    /// the source keeps for its watchOS/macOS slices has nothing to guard
    /// here, and `FakeAudioSession`'s own literal is then an independent
    /// check that the two agree.
    private static let cannotInterruptOthersCode = Int(AVAudioSession.ErrorCode.cannotInterruptOthers.rawValue)

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

    /// The caller's standing instruction: set by `activate()`, cleared by
    /// `deactivate()`. The source gates its three activation re-drive points
    /// on `playbackIntended` instead (~1128, ~1149, ~1452); this coordinator
    /// owns no player to read that from, so it tracks the same intent off its
    /// own two calls. Without it, a `deactivate()` issued while an activation
    /// is deferred -- behind the bounded retry, or behind a handback -- does
    /// nothing at all, and the deferral then activates a session moments
    /// after the caller explicitly asked for it to be released. Deliberately
    /// private: ADR 0008 fixes the consumer's surface at
    /// `activate()`/`deactivate()`, and this must work through those two.
    private var activationIntended = false

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

    /// Whether a scheduled handback is between its `deactivate()` and its
    /// continuation. `isActivated` cannot stand in for this: it is cleared
    /// only once the handback is *confirmed*, ~1s later on device, so a
    /// second `deactivate()` inside that window passes the `isActivated`
    /// guard and queues a second detached task -- which blocks on
    /// `sessionLock` for the rest of that second, occupying a cooperative-pool
    /// thread (the one thing this whole design must not do), and then, since
    /// only a successful *activation* bumps the generation, passes its
    /// generation check and issues a duplicate real
    /// `setActive(false, .notifyOthersOnDeactivation)` -- re-fanning the
    /// resume notification to every other audio app on the device.
    private var deactivationInFlight = false

    /// Whether a handback was asked for while one was already in flight. The
    /// request can't be served immediately and must not be dropped either:
    /// the in-flight one may yet decline as stale, in which case this request
    /// is the only thing left that would ever hand the session back.
    /// Consumed exactly once, by `drainRequestedDeactivation()`.
    private var deactivationRequested = false

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
    ///
    /// Also records the caller's standing intent, which every one of those
    /// automatic re-drives is gated on and which a later `deactivate()`
    /// withdraws -- see `activationIntended`.
    @discardableResult
    func activate() -> Bool {
        activationIntended = true
        switch attemptActivation() {
        case .activated:
            clearPendingActivation()
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
    ///
    /// Withdraws the standing intent first, and unconditionally -- *before*
    /// the `isActivated` guard, which an activation deferred behind the
    /// bounded retry or behind a handback has not yet set. Cancelling that
    /// deferral is the whole point: a deferred activation is exactly the
    /// state in which "the session isn't active" and "nothing is about to
    /// activate it" are two different claims, and only the first is a reason
    /// to return early.
    func deactivate() {
        activationIntended = false
        clearPendingActivation()
        guard isActivated else { return }
        guard !deactivationInFlight else {
            // Don't stack a second XPC call behind the first -- but don't
            // drop the request either. The in-flight handback may yet decline
            // as stale, because an activate() re-activated the session after
            // it was scheduled, and then this request is the only thing left
            // that would ever hand the session back. Re-driven from the
            // continuation below, by drainRequestedDeactivation().
            deactivationRequested = true
            return
        }
        deactivationInFlight = true
        let generation = activationGeneration
        Task { [self] in
            let handedBack = await Task.detached(priority: .userInitiated) {
                self.deactivateLocked(ifGenerationIs: generation)
            }.value
            deactivationInFlight = false
            if handedBack, activationGeneration == generation {
                isActivated = false
            }
            // Coordinator-internal by design: there is no public resume, no
            // closure parameter on activate(), and no AsyncStream on the
            // seam. A deferred activation is finished here, inline, rather
            // than handed to a caller to orchestrate.
            resumeDeferredActivationAfterHandback()
            drainRequestedDeactivation()
            deactivationSettledCount += 1
        }
    }

    private func resumeDeferredActivationAfterHandback() {
        guard activationPending else { return }
        guard activationIntended else {
            // The activate() that deferred has since been withdrawn by a
            // deactivate(). Clear the bookkeeping rather than leaving
            // activationPending latched, which would make every later
            // activation look like it already had a retry in flight.
            clearPendingActivation()
            return
        }
        clearPendingActivation()
        activate()
    }

    /// Re-drives a handback request that arrived while one was already in
    /// flight.
    ///
    /// Gated on the intent still being withdrawn: the dropped request may
    /// have been overtaken by an `activate()`, and tearing down *that*
    /// session is precisely the failure the generation check exists to
    /// prevent. Each request re-drives at most once -- it is consumed before
    /// the re-drive -- so a persistently failing handback can't turn this
    /// into an unbounded XPC loop; the next `deactivate()` retries it
    /// instead, which is what `isActivated` staying set on an unconfirmed
    /// handback is for.
    private func drainRequestedDeactivation() {
        guard deactivationRequested else { return }
        deactivationRequested = false
        guard !activationIntended else { return }
        deactivate()
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
    /// since it was scheduled. The generation check and the `setActive` call
    /// both run under `sessionLock`, so neither can interleave with a
    /// concurrent `activateLocked()`.
    ///
    /// The outcome is carried back out of the lock and only then logged, as
    /// the source does (~1585): logging writes, and the main actor may be
    /// sitting in `activateLocked()`'s `lockIfAvailable()` waiting on this
    /// same lock.
    private nonisolated func deactivateLocked(ifGenerationIs expected: Int) -> Bool {
        let outcome: DeactivationOutcome
        sessionLock.lock()
        if activationGeneration != expected {
            outcome = .stale
        } else {
            do {
                try session.setActive(false, options: .notifyOthersOnDeactivation)
                outcome = .deactivated
            } catch {
                outcome = .failed(error)
            }
        }
        sessionLock.unlock()

        switch outcome {
        case .deactivated:
            return true
        case .failed(let error):
            // The one wholly silent degrade in this file, and why it gets a
            // log line rather than a bare `return false`: every other audio
            // app on the device was waiting on `.notifyOthersOnDeactivation`
            // to learn it may resume, and now never hears it. Nothing on
            // screen marks that, and `isActivated` deliberately stays set so
            // the next `deactivate()` retries -- which makes a *persistently*
            // failing handback invisible too.
            //
            // CLAUDE.md's capture-site rule would put an
            // `ErrorReporter.report` beside this log, since how often
            // mediaserverd refuses a handback in the field is an aggregate
            // question no single device's log can answer. It isn't wired here
            // because this type takes no dependency beyond its session seam
            // and has no consumer yet (ADR 0008); the injection point belongs
            // with the `PlaybackController` that arrives in issue #138, where
            // a reporter is already in scope.
            log.error("Failed to deactivate audio session: \(error)")
            return false
        case .stale:
            log.info("Skipped deferred audio session deactivation; the session was re-activated")
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

    /// Drops a deferred activation along with whatever was going to re-drive
    /// it. Mirrors the source's `clearPendingSessionActivation()` (~1248).
    private func clearPendingActivation() {
        activationPending = false
        cancelRetryTask()
    }

    /// Schedules a bounded sequence of retries after a `CannotInterruptOthers`
    /// failure. Deliberately does not busy-loop: attempts are spaced
    /// `retryDelay` apart and stop after `maxRetryAttempts`.
    private func scheduleRetry() {
        // Only while the caller still wants the session (source ~1128). The
        // source pairs this with `isForegrounded`, which this coordinator has
        // no equivalent for -- it owns no app-lifecycle state.
        guard activationIntended else { return }
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
                // Bail if the intent was withdrawn, or the deferral resolved
                // some other way, while this tick was asleep (source ~1149).
                guard !Task.isCancelled, self.activationIntended, self.activationPending else { return }
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
