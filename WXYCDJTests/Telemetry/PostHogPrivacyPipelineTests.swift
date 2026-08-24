//
//  PostHogPrivacyPipelineTests.swift
//  WXYCDJTests
//
//  The end-to-end belt to AnalyticsPrivacyFilterTests' suspenders (issue
//  #108, mirroring SentryPrivacyPipelineTests' role for issue #106): capture
//  a real event through the real, started PostHog SDK -- the whole
//  TelemetryBootstrap.startAnalytics(apiKey:host:) pipeline, `personProfiles
//  = .never`, and the `beforeSend` allowlist filter -- and inspect what
//  actually reached the serialized properties.
//
//  Reaches PostHog-touching behavior exclusively through
//  TelemetryBootstrap.debugCaptureAnalyticsEventProperties(_:apiKey:host:),
//  the `#if DEBUG`-only test hook -- this file has no `import PostHog` and
//  cannot: WXYCDJTests is never linked against the PostHog package (see
//  project.yml's PostHog package comment), so the hook's plain `[String:
//  Any]` return is the only way to inspect a captured event here.
//
//  `.serialized`, for the identical reason SentryPrivacyPipelineTests needs
//  it: every test resets and reads `TelemetryBootstrap
//  .lastAnalyticsEventProperties` (a file-private `nonisolated(unsafe)
//  static var`) and calls `PostHogSDK.shared.close()`/`setup(_:)` -- both
//  process-wide state Swift Testing's default parallelism would race.
//
//  Created by Jake Bromberg on 08/24/26.
//  Copyright © 2026 WXYC. All rights reserved.
//

import Foundation
import Testing
@testable import WXYCDJ

/// An event with a property key that was never added to
/// `AnalyticsPrivacyAllowlist.allowedKeys` -- exists only to prove the
/// runtime backstop actually drops such a key when it reaches the real SDK,
/// not merely in the pure function `AnalyticsPrivacyFilterTests` already
/// covers. No real event in the catalog looks like this; that's the point.
private struct RogueTestEvent: AnalyticsEvent {
    static let name = "rogue_test_event"
    var properties: [String: AnalyticsPropertyValue] {
        ["not_on_any_allowlist": .int(42)]
    }
}

@Suite("PostHog privacy pipeline (end-to-end)", .serialized)
struct PostHogPrivacyPipelineTests {
    /// Never the real project token this app ships with -- syntactically
    /// plausible so `PostHogConfig` accepts it, and the hook's default host is
    /// loopback, so nothing this suite does can reach a live PostHog project.
    private static let testAPIKey = "phc_test_00000000000000000000000000000000"

    @Test("$process_person_profile is false, per personProfiles = .never")
    func processPersonProfileFlagIsFalse() throws {
        let properties = try #require(TelemetryBootstrap.debugCaptureAnalyticsEventProperties(
            SearchPerformedEvent(source: .server, resultCount: 1, queryLength: 4),
            apiKey: Self.testAPIKey
        ))

        #expect(properties["$process_person_profile"] as? Bool == false)
    }

    @Test("a real event's own properties survive, with build_type stamped alongside them")
    func realEventPropertiesSurviveWithBuildType() throws {
        let properties = try #require(TelemetryBootstrap.debugCaptureAnalyticsEventProperties(
            SignInCompletedEvent(method: .otp),
            apiKey: Self.testAPIKey
        ))

        #expect(properties["method"] as? String == "otp")
        // WXYCDJTests is a DEBUG build (see BuildEnvironment.current).
        #expect(properties["build_type"] as? String == "development")
    }

    @Test("a property key with no entry in the allowlist is dropped, even through the real SDK")
    func unallowlistedKeyIsDroppedEndToEnd() throws {
        let properties = try #require(TelemetryBootstrap.debugCaptureAnalyticsEventProperties(
            RogueTestEvent(),
            apiKey: Self.testAPIKey
        ))

        #expect(properties["not_on_any_allowlist"] == nil)
        // The filter drops the key, not the whole event -- PostHog's own
        // $-context is still present.
        #expect(properties["$process_person_profile"] as? Bool == false)
    }
}
