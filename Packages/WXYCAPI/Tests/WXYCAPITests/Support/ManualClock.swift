//
//  ManualClock.swift
//  WXYCAPITests
//
//  A manually-advanced monotonic instant source for tests that need
//  deterministic control over time-gated production code — issue #81's
//  ConnectivityMonitor half-open-probe cooldown is the first consumer. No
//  wall-clock sleeps: a test advances the clock by exactly the interval it
//  wants to simulate, then asserts. Lock-guarded Sendable so ``provider`` can
//  be handed to a `@Sendable () -> ContinuousClock.Instant` injection point.
//
//  Created by Jake on 08/16/26.
//  Copyright © 2026 WXYC. All rights reserved.
//

import Foundation
import os

final class ManualClock: Sendable {
    private let state: OSAllocatedUnfairLock<ContinuousClock.Instant>

    init(now: ContinuousClock.Instant = ContinuousClock.now) {
        state = OSAllocatedUnfairLock(initialState: now)
    }

    var now: ContinuousClock.Instant { state.withLock { $0 } }

    func advance(by seconds: TimeInterval) {
        state.withLock { $0 = $0.advanced(by: .seconds(seconds)) }
    }

    /// A `@Sendable () -> ContinuousClock.Instant` closure reading the current
    /// simulated time — pass directly to any `now:`-style injection point.
    var provider: @Sendable () -> ContinuousClock.Instant {
        let state = self.state
        return { state.withLock { $0 } }
    }
}
