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

    init() {
        // Unbounded (the default) on purpose: a test emits before the
        // controller's consumer task has necessarily reached its first
        // `await`, and an event dropped there would make the whole suite
        // timing-dependent.
        let (stream, continuation) = AsyncStream<PlaybackEngineEvent>.makeStream()
        self.events = stream
        self.continuation = continuation
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
    func pause() { record(.pause) }
    func advance() { record(.advance) }
    func seek(to time: TimeInterval) { record(.seek(time)) }

    private func record(_ command: Command) {
        state.withLock { $0.append(command) }
    }
}
