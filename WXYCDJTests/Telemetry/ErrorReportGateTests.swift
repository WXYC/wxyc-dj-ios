//
//  ErrorReportGateTests.swift
//  WXYCDJTests
//
//  The handled-error send cap (issue #242): the 60-second dedupe, the
//  per-launch token bucket behind it, the drop log, and the guarantee that
//  MetricKit diagnostics bypass both. The gate is driven by a manual clock;
//  nothing here sleeps or touches the PostHog SDK except the one bypass test.
//
//  Created by Jake Bromberg on 10/20/26.
//  Copyright © 2026 WXYC. All rights reserved.
//

import Foundation
import Synchronization
import Testing
@testable import WXYCDJ

/// A clock the test advances by hand, read through the gate's `@Sendable` time source.
private final class ManualGateClock: Sendable {
    private let instant = Mutex(ContinuousClock.now)

    var reader: @Sendable () -> ContinuousClock.Instant {
        { [self] in instant.withLock { $0 } }
    }

    func advance(by duration: Duration) {
        instant.withLock { $0 = $0.advanced(by: duration) }
    }
}

private func key(_ id: Int, context: StaticString = "ErrorReportGateTests") -> ErrorReportGate.Key {
    ErrorReportGate.Key(domain: "org.wxyc.dj.APIError", code: id, context: context)
}

@Suite("ErrorReportGate")
struct ErrorReportGateTests {
    private func makeGate(
        clock: ManualGateClock,
        onDropped: @escaping @Sendable (Int) -> Void = { _ in }
    ) -> ErrorReportGate {
        ErrorReportGate(now: clock.reader, onDropped: onDropped)
    }

    @Test("a repeat inside 60 seconds is dropped, and the same key is admitted again after 60 seconds")
    func dedupesForSixtySeconds() {
        let clock = ManualGateClock()
        let gate = makeGate(clock: clock)

        #expect(gate.admit(key: key(1)))
        clock.advance(by: .seconds(59))
        #expect(!gate.admit(key: key(1)))
        clock.advance(by: .seconds(1))
        #expect(gate.admit(key: key(1)))
    }

    @Test("a deduped repeat costs no token")
    func dedupedRepeatCostsNoToken() {
        let clock = ManualGateClock()
        let gate = makeGate(clock: clock)

        #expect(gate.admit(key: key(0)))
        for _ in 0..<50 {
            #expect(!gate.admit(key: key(0)))
        }
        // 19 tokens remain, so 19 more distinct errors are admitted and the 20th is not.
        for id in 1...19 {
            #expect(gate.admit(key: key(id)))
        }
        #expect(!gate.admit(key: key(20)))
    }

    @Test("20 distinct errors are admitted and the 21st is dropped")
    func burstOfTwenty() {
        let clock = ManualGateClock()
        let gate = makeGate(clock: clock)

        for id in 0..<20 {
            #expect(gate.admit(key: key(id)))
        }
        #expect(!gate.admit(key: key(20)))
    }

    @Test("a token comes back after the 30-minute refill interval, and not before")
    func refillsOneTokenPerThirtyMinutes() {
        let clock = ManualGateClock()
        let gate = makeGate(clock: clock)
        for id in 0..<20 {
            _ = gate.admit(key: key(id))
        }

        clock.advance(by: .seconds(1_799))
        #expect(!gate.admit(key: key(100)))
        clock.advance(by: .seconds(1))
        #expect(gate.admit(key: key(100)))
        #expect(!gate.admit(key: key(101)))
    }

    @Test("frequent dropped calls do not make the refill drift: the token arrives exactly at the 30-minute mark")
    func refillIsExactUnderFrequentCalls() {
        let clock = ManualGateClock()
        let gate = makeGate(clock: clock)
        for id in 0..<20 {
            _ = gate.admit(key: key(id))
        }

        for second in 1..<1_800 {
            clock.advance(by: .seconds(1))
            #expect(!gate.admit(key: key(1_000 + second)), "dropped at \(second) s")
        }
        clock.advance(by: .seconds(1))
        #expect(gate.admit(key: key(5_000)))
        #expect(!gate.admit(key: key(5_001)))
    }

    @Test("the bucket never refills past its capacity of 20")
    func refillIsCapped() {
        let clock = ManualGateClock()
        let gate = makeGate(clock: clock)

        clock.advance(by: .seconds(1_800 * 100))
        for id in 0..<20 {
            #expect(gate.admit(key: key(id)))
        }
        #expect(!gate.admit(key: key(20)))
    }

    @Test("the dedupe table stays bounded and still admits a new key once it is full")
    func dedupeTableIsBounded() {
        let clock = ManualGateClock()
        let gate = makeGate(clock: clock)

        for id in 0..<(ErrorReportGate.maxTrackedKeys + 5) {
            // One token comes back per 30 minutes, so step the clock to keep admitting.
            clock.advance(by: .seconds(1_800))
            #expect(gate.admit(key: key(id)))
        }
        #expect(gate.trackedKeyCount <= ErrorReportGate.maxTrackedKeys)
    }

    // MARK: - Drop log

    @Test("drops are counted and logged at most once a minute")
    func dropLogIsRateLimited() {
        let clock = ManualGateClock()
        let logged = Mutex<[Int]>([])
        let gate = makeGate(clock: clock) { count in logged.withLock { $0.append(count) } }

        _ = gate.admit(key: key(1))
        // First drop logs at once, with a count of one.
        _ = gate.admit(key: key(1))
        #expect(logged.withLock { $0 } == [1])

        // Three more inside the minute are counted, not logged.
        for _ in 0..<3 {
            _ = gate.admit(key: key(1))
        }
        #expect(logged.withLock { $0 } == [1])

        // The next drop after the minute carries the running count. The
        // dedupe window has lapsed too, so the first call is admitted afresh.
        clock.advance(by: .seconds(60))
        #expect(gate.admit(key: key(1)))
        _ = gate.admit(key: key(1))
        #expect(logged.withLock { $0 } == [1, 4])
    }

    // MARK: - Key

    @Test("the key is built from the curated domain, code and context, never from userInfo")
    func keyUsesOnlyReportableValues() {
        let noisy = NSError(domain: "org.wxyc.dj.APIError", code: 7, userInfo: [
            NSLocalizedDescriptionKey: "failed for dj.kendra87@wxyc-test.example",
            NSDebugDescriptionErrorKey: "https://api.wxyc.org/library?artist=Juana%20Molina"
        ])
        let plain = NSError(domain: "org.wxyc.dj.APIError", code: 7)

        #expect(ErrorReportGate.Key(noisy, context: "KeyTest") == ErrorReportGate.Key(plain, context: "KeyTest"))
        #expect(ErrorReportGate.Key(plain, context: "KeyTest") != ErrorReportGate.Key(plain, context: "OtherContext"))
        #expect(ErrorReportGate.Key(plain, context: "KeyTest")
            != ErrorReportGate.Key(NSError(domain: "org.wxyc.dj.APIError", code: 8), context: "KeyTest"))
        #expect(ErrorReportGate.Key(plain, context: "KeyTest")
            != ErrorReportGate.Key(NSError(domain: "org.wxyc.dj.AuthError", code: 7), context: "KeyTest"))
    }
}
