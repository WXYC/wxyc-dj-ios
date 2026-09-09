//
//  ForegroundReentryTrackerTests.swift
//  WXYCDJTests
//
//  Pins ForegroundReentryTracker (issue #118 item 4): an `.active` scenePhase
//  transition counts as a foreground re-entry only once the app has actually
//  been backgrounded, so the cold-launch activation (already covered by the
//  launch .task) and an inactive -> active blip both answer false — whether or
//  not SwiftUI delivers an onChange for the launch activation at all.
//
//  Created by Jake Bromberg on 08/24/26.
//  Copyright © 2026 WXYC. All rights reserved.
//

import Testing
@testable import WXYCDJ

@Suite("ForegroundReentryTracker")
struct ForegroundReentryTrackerTests {
    /// Cold launch **with** the launch activation delivered — the case issue
    /// #118 item 4 was filed about. The launch `.task` already refreshes, so
    /// this `.active` must not.
    @Test func theColdLaunchActivationIsNotAGenuineReentry() {
        let tracker = ForegroundReentryTracker()

        #expect(tracker.isGenuineForegroundReentry() == false)
    }

    /// Cold launch **without** it. Whether SwiftUI raises
    /// `onChange(of: scenePhase)` for the launch activation is not guaranteed,
    /// and the first shape of this type consumed the first `.active`
    /// unconditionally — which, in this world, would eat the first *genuine*
    /// re-entry and silently skip `refreshCatalog(trigger: .foreground)`
    /// forever after one background cycle. Keying on a seen `.background`
    /// makes the two worlds indistinguishable from here.
    @Test func aRealReentryCountsEvenIfTheLaunchActivationNeverFired() {
        var tracker = ForegroundReentryTracker()
        tracker.noteBackground()  // no prior .active was ever delivered

        #expect(tracker.isGenuineForegroundReentry() == true)
    }

    @Test func anActivationAfterABackgroundIsAGenuineReentry() {
        var tracker = ForegroundReentryTracker()
        _ = tracker.isGenuineForegroundReentry()  // the cold-launch activation
        tracker.noteBackground()

        #expect(tracker.isGenuineForegroundReentry() == true)
    }

    /// Every subsequent background -> active cycle counts too — the tracker
    /// latches "has been backgrounded" rather than consuming one allowance.
    @Test func repeatedBackgroundForegroundCyclesEachCount() {
        var tracker = ForegroundReentryTracker()
        _ = tracker.isGenuineForegroundReentry()

        for _ in 0..<3 {
            tracker.noteBackground()
            #expect(tracker.isGenuineForegroundReentry() == true)
        }
    }

    /// An `.active -> .inactive -> .active` blip — Control Centre, the app
    /// switcher, an incoming call — never reaches `.background`, so it is not
    /// a return from background and there is nothing to top up. The first
    /// shape of this type treated it as a genuine re-entry.
    @Test func anInactiveToActiveBlipIsNotAGenuineReentry() {
        let tracker = ForegroundReentryTracker()
        _ = tracker.isGenuineForegroundReentry()  // cold-launch activation

        // .inactive drives no tracker call at all (the `default:` arm), so the
        // blip's second .active arrives with no .background in between.
        #expect(tracker.isGenuineForegroundReentry() == false)
    }

    /// A blip *after* a real background cycle still counts — once the app has
    /// been backgrounded the clone may be stale, and a spurious extra refresh
    /// is a cheap 304, whereas suppressing a real one strands the clone. This
    /// pins the deliberate asymmetry so nobody "fixes" it into a one-shot.
    @Test func aBlipAfterARealBackgroundStillCounts() {
        var tracker = ForegroundReentryTracker()
        tracker.noteBackground()
        _ = tracker.isGenuineForegroundReentry()

        #expect(tracker.isGenuineForegroundReentry() == true)
    }
}
