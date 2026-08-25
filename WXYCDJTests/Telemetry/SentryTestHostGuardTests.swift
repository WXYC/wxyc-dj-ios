//
//  SentryTestHostGuardTests.swift
//  WXYCDJTests
//
//  Pins issue #119's test-host guard on TelemetryBootstrap.start() (Sentry)
//  -- the Sentry counterpart to issue #116's AnalyticsTestHostGuardTests
//  (WXYCDJTests/Telemetry/AnalyticsPrivacyFilterTests.swift), which guards
//  TelemetryBootstrap.startAnalytics() (PostHog) with the identical
//  predicate. WXYCDJTests is a host-app test bundle (TEST_HOST points at
//  WXYCDJ.app/WXYCDJ), so @main WXYCDJApp -> AppDelegate.init() runs before
//  any test does; without this guard every CI run and every local
//  `xcodebuild test` starts the real Sentry SDK against the production DSN
//  and files a real event against the `wxyc-dj-ios` project, attributed to a
//  build that doesn't exist.
//
//  `start()` returns a discardable Bool -- true if the real SDK was
//  started, false if the call was a no-op -- specifically so this guard is
//  provable from the test bundle without linking the Sentry package:
//  WXYCDJTests is never linked against Sentry (see project.yml's Sentry
//  package comment), so there is no `SentrySDK.isEnabled` or similar this
//  suite could otherwise inspect. Calling the real, guarded `start()`
//  in-process is safe: under the guard it does nothing at all (never
//  touches `SentrySDK`), so it can't interfere with
//  `SentryPrivacyPipelineTests`, which reconfigures the SDK against its own
//  test DSN via `start(dsn:)` on every test regardless of whether this call
//  ever ran (see that suite's header for why it doesn't depend on it).
//
//  Created by Jake Bromberg on 08/24/26.
//  Copyright © 2026 WXYC. All rights reserved.
//

import Foundation
import Testing
@testable import WXYCDJ

@Suite("TelemetryBootstrap.start() test host guard")
struct SentryTestHostGuardTests {
    @Test("a real call under the test runner is a no-op, not a production start")
    func testRunnerSkipsProductionStart() {
        // This process really is a test run (WXYCDJTests is a host-app
        // bundle), so the guard's predicate -- exercised directly in
        // AnalyticsTestHostGuardTests -- is `true` here. This test goes one
        // step further and calls the real, unguarded production entry point
        // itself, so a future edit that drops the guard from `start()`'s
        // body (rather than from the shared predicate) still fails this
        // suite.
        #expect(TelemetryBootstrap.start() == false)
    }
}
