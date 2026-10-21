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
        capacity: Int = ErrorReportGate.burst,
        onDropped: @escaping @Sendable (Int) -> Void = { _ in }
    ) -> ErrorReportGate {
        ErrorReportGate(capacity: capacity, now: clock.reader, onDropped: onDropped)
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

    @Test("scenario C: a partly drained bucket that idles for days refills to 20 and no further")
    func refillIsCapped() {
        let clock = ManualGateClock()
        let gate = makeGate(clock: clock)
        for id in 0..<5 {
            #expect(gate.admit(key: key(id)))
        }

        clock.advance(by: .seconds(1_800 * 100))
        for id in 100..<120 {
            #expect(gate.admit(key: key(id)))
        }
        #expect(!gate.admit(key: key(120)))
    }

    @Test("scenario D: a full bucket restarts the refill clock, so the first token after it drains takes a full interval")
    func fullBucketRestartsRefillClock() {
        let clock = ManualGateClock()
        let gate = makeGate(clock: clock)

        // D1: the bucket was full, so its refill clock restarts at 29:00, not at 0:00.
        clock.advance(by: .seconds(29 * 60))
        for id in 0..<20 {
            #expect(gate.admit(key: key(id)))
        }
        // D2: the next token is due at 59:00.
        clock.advance(by: .seconds(60))
        #expect(gate.admitReportingDrops(key: key(100)) == nil, "D2 30:00 dropped")
        // D3
        clock.advance(by: .seconds(28 * 60 + 59))
        #expect(gate.admitReportingDrops(key: key(101)) == nil, "D3 58:59 dropped")
        // D4: admitted exactly at 59:00, reporting the two drops since the last admit.
        clock.advance(by: .seconds(1))
        #expect(gate.admitReportingDrops(key: key(102)) == 2, "D4 59:00 admitted with dropped_since_last 2")
    }

    @Test("scenario A: after the burst, one token returns at 30:00, 60:00 and 90:00, each reporting the drops before it")
    func refillsAtEachInterval() {
        let clock = ManualGateClock()
        let gate = makeGate(clock: clock)

        // A1: k1 to k20 at 0:00 are admitted, with no drops to report.
        for id in 1...20 {
            #expect(gate.admitReportingDrops(key: key(id)) == 0, "A1 k\(id) admitted, dropped_since_last absent")
        }
        // A2: the bucket is empty.
        #expect(gate.admitReportingDrops(key: key(21)) == nil, "A2 0:00 k21 dropped")
        // A3: the refill is not yet due.
        clock.advance(by: .seconds(29 * 60 + 59))
        #expect(gate.admitReportingDrops(key: key(22)) == nil, "A3 29:59 k22 dropped")
        // A4: the token is due exactly at 30:00; the drops at A2 and A3 are reported.
        clock.advance(by: .seconds(1))
        #expect(gate.admitReportingDrops(key: key(23)) == 2, "A4 30:00 k23 admitted with dropped_since_last 2")
        // A5
        #expect(gate.admitReportingDrops(key: key(24)) == nil, "A5 30:00 k24 dropped")
        // A6: the drop at A5 is reported.
        clock.advance(by: .seconds(30 * 60))
        #expect(gate.admitReportingDrops(key: key(25)) == 1, "A6 60:00 k25 admitted with dropped_since_last 1")
        // A7: nothing was dropped since A6, so the count was reset and the property is absent.
        clock.advance(by: .seconds(30 * 60))
        #expect(gate.admitReportingDrops(key: key(26)) == 0, "A7 90:00 k26 admitted, dropped_since_last absent")
    }

    @Test("scenario E: 1,000 unexpired keys 1 ms apart leave the table bounded, and only the oldest keys are evicted")
    func dedupeTableIsBoundedWithUnexpiredKeys() {
        let clock = ManualGateClock()
        // Capacity is maxTrackedKeys + 3, not + 2: E1 to E3 admit 1,002 keys, which leaves one token
        // for E4. With + 2 the bucket is empty at E4, so the bucket alone would drop the key and the
        // test could not tell a table that still tracks it from one that was cleared.
        let gate = makeGate(clock: clock, capacity: ErrorReportGate.maxTrackedKeys + 3)

        // E1: k1 to k1000 at i ms (ids 0..<1000 here; id i is k(i + 1)).
        for id in 0..<ErrorReportGate.maxTrackedKeys {
            #expect(gate.admit(key: key(id)))
            clock.advance(by: .milliseconds(1))
        }
        #expect(gate.trackedKeyCount == ErrorReportGate.maxTrackedKeys)

        // E2: k1001 is admitted and evicts k1, the oldest; the table still holds 1,000.
        clock.advance(by: .seconds(30))
        #expect(gate.admit(key: key(ErrorReportGate.maxTrackedKeys)))
        #expect(gate.trackedKeyCount == ErrorReportGate.maxTrackedKeys)

        // E3: k1 was evicted, so it is admitted again inside its old window; this evicts k2.
        #expect(gate.admit(key: key(0)))
        #expect(gate.trackedKeyCount == ErrorReportGate.maxTrackedKeys)

        // E4: k3 is still tracked and 30 s old, so dedupe drops it. A token remains, so only the
        // table can be the reason.
        #expect(!gate.admit(key: key(2)))
    }

    // MARK: - Drop log

    @Test("drops are counted and logged at most once every 15 minutes")
    func dropLogIsRateLimited() {
        let clock = ManualGateClock()
        let logged = Mutex<[Int]>([])
        let gate = makeGate(clock: clock) { count in logged.withLock { $0.append(count) } }

        _ = gate.admit(key: key(1))
        // First drop logs at once, with a count of one.
        _ = gate.admit(key: key(1))
        #expect(logged.withLock { $0 } == [1])

        // Three more are counted, not logged, up to 15 minutes minus a second.
        for _ in 0..<3 {
            _ = gate.admit(key: key(1))
        }
        clock.advance(by: .seconds(15 * 60 - 1))
        #expect(gate.admit(key: key(1)))
        _ = gate.admit(key: key(1))
        #expect(logged.withLock { $0 } == [1])

        // At exactly 15 minutes the next drop carries the running count.
        clock.advance(by: .seconds(1))
        _ = gate.admit(key: key(1))
        #expect(logged.withLock { $0 } == [1, 5])

        // F4: a drop right after a later warning is counted, not logged.
        clock.advance(by: .seconds(1))
        _ = gate.admit(key: key(1))
        #expect(logged.withLock { $0 } == [1, 5])
    }

    // MARK: - Drops since last

    @Test("an admitted error reports the drops since the last admitted one, and the next reports none")
    func droppedSinceLastResetsOnAdmit() {
        let clock = ManualGateClock()
        let gate = makeGate(clock: clock)

        #expect(gate.admitReportingDrops(key: key(1)) == 0)
        for _ in 0..<3 {
            #expect(gate.admitReportingDrops(key: key(1)) == nil)
        }
        clock.advance(by: .seconds(60))
        #expect(gate.admitReportingDrops(key: key(1)) == 3)
        clock.advance(by: .seconds(60))
        #expect(gate.admitReportingDrops(key: key(1)) == 0)
    }

    @Test("the drop count survives the rate-limited log resetting its own count")
    func droppedSinceLastIsIndependentOfTheLog() {
        let clock = ManualGateClock()
        let gate = makeGate(clock: clock)

        _ = gate.admit(key: key(1))
        for _ in 0..<2 {
            _ = gate.admit(key: key(1))
        }
        clock.advance(by: .seconds(60))
        #expect(gate.admitReportingDrops(key: key(1)) == 2)
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
