//
//  ErrorReportGate.swift
//  WXYCDJ
//
//  The send cap on handled-error `$exception`s (issue #242): a 60-second
//  dedupe, then a per-launch token bucket. Foundation-only, so WXYCDJTests
//  drives it under `@testable import WXYCDJ` without linking PostHog.
//
//  Created by Jake Bromberg on 10/20/26.
//  Copyright © 2026 WXYC. All rights reserved.
//

import Foundation
import os

/// Decides whether a handled error may be sent to PostHog, so one device in a
/// retry loop cannot burn the exception cap the whole org shares (the free
/// plan's 100K a month is a hard stop; the server reporters already budget
/// about 50K of it -- wiki `patterns/error-tracking.md` §5).
///
/// Two gates, in this order, matching the server contract:
///
/// 1. **Dedupe, 60 seconds.** A key admitted less than ``dedupeWindow`` ago is
///    dropped. It runs first, so a suppressed repeat costs no token. The table
///    of recent keys is bounded at ``maxTrackedKeys``.
/// 2. **Token bucket.** Capacity ``burst`` (20), refilling one token every
///    ``refillInterval`` (30 minutes), which is a steady-state ceiling of 48 a
///    day. The bucket lives in memory, so it starts full at every launch. One
///    token per 30 minutes keeps a single stuck device to a small, fixed share
///    of the cap left over once the servers' budget is taken out, while a
///    burst of 20 still lets a real incident report each distinct failure
///    once (dedupe has already collapsed the repeats).
///
/// Dropped errors are counted and reported through `onDropped` at most once a
/// minute (a warning in `org.wxyc.dj`); they are never sent anywhere.
///
/// **Crashes are not gated.** Only `PostHogErrorReporter.report(_:context:extra:)`
/// consults this. MetricKit hangs and crashes (`report(diagnostic:)`) arrive in
/// at most one payload a day and a crash is the event least affordable to
/// drop; PostHog's own crash autocapture never touches the reporter at all.
///
/// The ``Key`` holds only values the event already carries -- the curated
/// error's domain and code and the `StaticString` context -- never a message,
/// so a future change that logs or sends it cannot open a leak channel.
final class ErrorReportGate: Sendable {
    /// What makes two errors "the same" for the dedupe window.
    struct Key: Hashable, Sendable {
        let domain: String
        let code: Int
        let context: String

        init(domain: String, code: Int, context: StaticString) {
            self.domain = domain
            self.code = code
            self.context = "\(context)"
        }

        /// The key for an error already through `curated(_:)` and `sanitized(_:)`.
        /// Reads domain and code only, never `userInfo` or any description.
        init(_ error: NSError, context: StaticString) {
            self.init(domain: error.domain, code: error.code, context: context)
        }
    }

    static let dedupeWindow: Duration = .seconds(60)
    static let burst = 20.0
    static let refillInterval: Duration = .seconds(30 * 60)
    static let maxTrackedKeys = 1_000
    static let dropLogInterval: Duration = .seconds(60)

    private struct State {
        var recent: [Key: ContinuousClock.Instant] = [:]
        var tokens = ErrorReportGate.burst
        var refilledAt: ContinuousClock.Instant
        var dropped = 0
        var droppedLoggedAt: ContinuousClock.Instant?
    }

    private let now: @Sendable () -> ContinuousClock.Instant
    private let onDropped: @Sendable (Int) -> Void
    private let state: OSAllocatedUnfairLock<State>

    /// - Parameters:
    ///   - now: Monotonic time source; tests inject a manual clock.
    ///   - onDropped: Receives the number of errors dropped since the last
    ///     report, at most once per ``dropLogInterval``.
    init(
        now: @escaping @Sendable () -> ContinuousClock.Instant = { ContinuousClock.now },
        onDropped: @escaping @Sendable (Int) -> Void = { ErrorReportGate.logDropped($0) }
    ) {
        self.now = now
        self.onDropped = onDropped
        state = OSAllocatedUnfairLock(initialState: State(refilledAt: now()))
    }

    /// Whether the error with this key may be sent. Admitting consumes a token
    /// and starts the key's dedupe window; a drop of either kind is counted.
    func admit(key: Key) -> Bool {
        let instant = now()
        let (admitted, report) = state.withLock { state -> (Bool, Int?) in
            if let last = state.recent[key], instant - last < Self.dedupeWindow {
                return (false, Self.recordDrop(&state, at: instant))
            }
            let refilled = state.tokens + (instant - state.refilledAt) / Self.refillInterval
            state.tokens = min(Self.burst, refilled)
            state.refilledAt = instant
            guard state.tokens >= 1 else {
                return (false, Self.recordDrop(&state, at: instant))
            }
            state.tokens -= 1
            Self.remember(key, at: instant, in: &state)
            return (true, nil)
        }
        if let report {
            onDropped(report)
        }
        return admitted
    }

    /// Number of keys in the dedupe table, for the bound test.
    var trackedKeyCount: Int {
        state.withLock { $0.recent.count }
    }

    /// Counts a drop; returns the running count when it is time to report it.
    private static func recordDrop(_ state: inout State, at instant: ContinuousClock.Instant) -> Int? {
        state.dropped += 1
        if let loggedAt = state.droppedLoggedAt, instant - loggedAt < dropLogInterval {
            return nil
        }
        defer {
            state.dropped = 0
            state.droppedLoggedAt = instant
        }
        return state.dropped
    }

    /// Records an admitted key, evicting expired entries and then the oldest so the table stays bounded.
    private static func remember(_ key: Key, at instant: ContinuousClock.Instant, in state: inout State) {
        if state.recent.count >= maxTrackedKeys, state.recent[key] == nil {
            state.recent = state.recent.filter { instant - $0.value < dedupeWindow }
            if state.recent.count >= maxTrackedKeys, let oldest = state.recent.min(by: { $0.value < $1.value }) {
                state.recent[oldest.key] = nil
            }
        }
        state.recent[key] = instant
    }

    private static let log = Logger(subsystem: "org.wxyc.dj", category: "telemetry")

    static func logDropped(_ count: Int) {
        log.warning("Dropped \(count, privacy: .public) handled-error report(s) over the send cap")
    }
}
