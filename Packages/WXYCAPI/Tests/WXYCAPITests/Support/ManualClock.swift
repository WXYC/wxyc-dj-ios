//
//  ManualClock.swift
//  WXYCAPITests
//
//  A manually-advanced Date source for tests that need deterministic control
//  over time-gated production code — issue #81's ConnectivityMonitor
//  half-open-probe cooldown is the first consumer. No wall-clock sleeps: a
//  test advances the clock by exactly the interval it wants to simulate, then
//  asserts. Lock-guarded Sendable so ``provider`` can be handed to a
//  `@Sendable () -> Date` injection point.
//
//  Created by Jake on 08/16/26.
//  Copyright © 2026 WXYC. All rights reserved.
//

import Foundation
import os

final class ManualClock: Sendable {
    private let state: OSAllocatedUnfairLock<Date>

    init(now: Date = Date(timeIntervalSince1970: 0)) {
        state = OSAllocatedUnfairLock(initialState: now)
    }

    var now: Date { state.withLock { $0 } }

    func advance(by seconds: TimeInterval) {
        state.withLock { $0 = $0.addingTimeInterval(seconds) }
    }

    /// A `@Sendable () -> Date` closure reading the current simulated time —
    /// pass directly to any `now:`-style injection point.
    var provider: @Sendable () -> Date {
        let state = self.state
        return { state.withLock { $0 } }
    }
}
