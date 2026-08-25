//
//  ForegroundReentryTrackerTests.swift
//  WXYCDJTests
//
//  Pins ForegroundReentryTracker (issue #118 item 4): the cold-launch
//  inactive -> active scenePhase transition is consumed silently (the
//  launch .task already refreshes for it), and every subsequent .active
//  call is reported as a genuine foreground re-entry.
//
//  Created by Jake Bromberg on 08/24/26.
//  Copyright © 2026 WXYC. All rights reserved.
//

import Testing
@testable import WXYCDJ

@Suite("ForegroundReentryTracker")
struct ForegroundReentryTrackerTests {
    @Test func theFirstActivationIsNotAGenuineReentry() {
        var tracker = ForegroundReentryTracker()

        #expect(tracker.isGenuineForegroundReentry() == false)
    }

    @Test func everyActivationAfterTheFirstIsAGenuineReentry() {
        var tracker = ForegroundReentryTracker()
        _ = tracker.isGenuineForegroundReentry()  // the cold-launch activation

        #expect(tracker.isGenuineForegroundReentry() == true)
        #expect(tracker.isGenuineForegroundReentry() == true)  // and every one after that
    }
}
