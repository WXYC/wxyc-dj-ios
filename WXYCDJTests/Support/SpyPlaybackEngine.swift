//
//  SpyPlaybackEngine.swift
//  WXYCDJTests
//
//  A recording PlaybackEngine double for PlaybackControllerTests (issue
//  #144). Records every command in order so a test can assert what the
//  controller asked the engine to do -- including the exact item list a
//  post-403 refetch re-loads, which is what proves it resumed on the same
//  track rather than restarting the album -- and lets the test drive the
//  event stream by hand, so a `.timeControl` or a `.failed(.mediaForbidden)`
//  arrives exactly when the test wants it. Lock-guarded, matching
//  SpyBinStore/SpyErrorReporter: OSAllocatedUnfairLock is unconditionally
//  Sendable regardless of what it guards.
//
//  It emits nothing on its own by default, which is a deliberate default and
//  also a known blind spot: `emitTimeControlOnPause()` opts a test into the
//  one place the real engine answers a command with an event, and the reason
//  that opt-in exists is that its absence let a defect through review. See
//  that method.
//
//  Created by Jake Bromberg on 08/30/26.
//  Copyright © 2026 WXYC. All rights reserved.
//

import Foundation
import os
@testable import WXYCDJ

final class SpyPlaybackEngine: PlaybackEngine {
    /// One recorded command. `load` carries its items so a test can assert on
    /// the queue the controller handed over, not merely that it handed one.
    enum Command: Equatable {
        case load([PlaybackItem])
        case play
        case pause
        case advance
        case seek(TimeInterval)
    }

    let events: AsyncStream<PlaybackEngineEvent>
    private let continuation: AsyncStream<PlaybackEngineEvent>.Continuation
    private let state = OSAllocatedUnfairLock(initialState: [Command]())
    private let terminated = OSAllocatedUnfairLock(initialState: false)
    private let autoEmitsTimeControlOnPause = OSAllocatedUnfairLock(initialState: false)

    /// Makes ``pause()`` yield `.timeControl(isPlaying: false)`, the way
    /// `AVQueuePlayerEngine` really does — `player.pause()` moves
    /// `timeControlStatus`, whose KVO observer yields exactly that.
    ///
    /// **Opt-in, because turning it on by default would change what every
    /// existing test measures.** Most of them assert an intermediate state
    /// right after a command, and an implicit event arriving a turn later
    /// would fold a second concern into each of them. It is opt-in rather than
    /// absent because leaving it out entirely is what let a real defect
    /// through review: `stop()` clears the Now Playing card and calls
    /// `engine.pause()` in one main-actor turn, the production engine answers
    /// that pause a turn later, and a `PlaybackController` that applied the
    /// answer ungated re-committed a blank card. A spy that emits nothing
    /// asserted the intermediate state and passed.
    func emitTimeControlOnPause() {
        autoEmitsTimeControlOnPause.withLock { $0 = true }
    }

    init() {
        // Unbounded (the default) on purpose: a test emits before the
        // controller's consumer task has necessarily reached its first
        // `await`, and an event dropped there would make the whole suite
        // timing-dependent.
        let (stream, continuation) = AsyncStream<PlaybackEngineEvent>.makeStream()
        self.events = stream
        self.continuation = continuation
        // Records that the stream stopped being consumed -- either because
        // `finish()` was called or because the consuming task was cancelled.
        // That second case is the only observable proof that
        // `PlaybackController.deinit` cancelled its events task; without it a
        // leaked, parked consumer looks exactly like a healthy one.
        let terminated = self.terminated
        continuation.onTermination = { _ in
            terminated.withLock { $0 = true }
        }
    }

    /// Whether the event stream stopped being consumed. See `init`.
    var isEventStreamTerminated: Bool { terminated.withLock { $0 } }

    /// Ends the stream, as a real engine's teardown would. `deinit` calls it
    /// too, so a spy that outlives nothing still can't strand a consumer.
    func finish() {
        continuation.finish()
    }

    deinit {
        continuation.finish()
    }

    /// Every command, in call order.
    var commands: [Command] { state.withLock { $0 } }

    /// Just the `load` payloads, which most assertions are about.
    var loads: [[PlaybackItem]] {
        commands.compactMap { if case .load(let items) = $0 { return items } else { return nil } }
    }

    /// Feed the controller an event, as the real engine's observers would.
    func emit(_ event: PlaybackEngineEvent) {
        continuation.yield(event)
    }

    // MARK: PlaybackEngine

    func load(_ items: [PlaybackItem]) { record(.load(items)) }
    func play() { record(.play) }
    func pause() {
        record(.pause)
        if autoEmitsTimeControlOnPause.withLock({ $0 }) {
            emit(.timeControl(isPlaying: false))
        }
    }
    func advance() { record(.advance) }
    func seek(to time: TimeInterval) { record(.seek(time)) }

    private func record(_ command: Command) {
        state.withLock { $0.append(command) }
    }
}
