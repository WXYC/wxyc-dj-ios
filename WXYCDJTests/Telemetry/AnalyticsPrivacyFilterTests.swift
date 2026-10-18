//
//  AnalyticsPrivacyFilterTests.swift
//  WXYCDJTests
//
//  Pins the pure half of issue #108's runtime backstop --
//  `AnalyticsPrivacyAllowlist.filterNonSDKProperties(_:)` -- independent of
//  the real PostHog SDK: a `$`-prefixed key (PostHog's own context, plus the
//  `$process_person_profile` flag the `personProfiles = .never` contract item
//  depends on) survives untouched, and a non-allowlisted, non-`$` key is
//  dropped -- plus the one exception to the carve-out, `personPayloadKeys`
//  (`$set`/`$set_once`/`$groups`), which are person data rather than SDK
//  context and are dropped despite their `$`. The end-to-end version of the
//  same guarantee, run through the real started SDK, is
//  `PostHogPrivacyPipelineTests`.
//
//  Created by Jake Bromberg on 08/24/26.
//  Copyright © 2026 WXYC. All rights reserved.
//

import Foundation
import Testing
@testable import WXYCDJ

@Suite("AnalyticsPrivacyAllowlist.filterNonSDKProperties")
struct AnalyticsPrivacyFilterTests {
    @Test("a $-prefixed key survives regardless of value, including the person-processing flag")
    func dollarPrefixedKeysSurvive() {
        let filtered = AnalyticsPrivacyAllowlist.filterNonSDKProperties([
            "$process_person_profile": false,
            "$app_version": "0.1.0",
            "$os_version": "18.4",
        ])

        #expect(filtered["$process_person_profile"] as? Bool == false)
        #expect(filtered["$app_version"] as? String == "0.1.0")
        #expect(filtered["$os_version"] as? String == "18.4")
    }

    @Test("an allowlisted non-$ key survives")
    func allowlistedKeysSurvive() {
        let filtered = AnalyticsPrivacyAllowlist.filterNonSDKProperties([
            "method": "otp",
            "build_type": "development",
        ])

        #expect(filtered["method"] as? String == "otp")
        #expect(filtered["build_type"] as? String == "development")
    }

    /// posthog-ios attaches these to the `Application Installed`/`Updated`/
    /// `Opened` events `captureApplicationLifecycleEvents = true` turns on.
    /// They're the payload that makes those events worth keeping — without
    /// `from_background` an `Application Opened` can't tell a cold launch from
    /// a foreground resume — so they're named in a separate, reviewed set
    /// rather than dropped along with everything else non-`$`.
    @Test("the SDK's own lifecycle-event keys survive")
    func sdkLifecycleKeysSurvive() {
        let filtered = AnalyticsPrivacyAllowlist.filterNonSDKProperties([
            "from_background": false,
            "version": "0.1.0",
            "build": 42,
            "previous_version": "0.0.9",
            "previous_build": 41,
        ])

        #expect(filtered.count == 5)
        #expect(filtered["from_background"] as? Bool == false)
        #expect(filtered["previous_version"] as? String == "0.0.9")
    }

    @Test("a non-allowlisted, non-$ key is dropped")
    func unallowlistedKeysAreDropped() {
        let filtered = AnalyticsPrivacyAllowlist.filterNonSDKProperties([
            "method": "otp",
            "search_query": "juana molina",  // never a real property this app would emit
        ])

        #expect(filtered["method"] as? String == "otp")
        #expect(filtered["search_query"] == nil)
    }

    @Test("an empty dict filters to an empty dict")
    func emptyDictionaryStaysEmpty() {
        #expect(AnalyticsPrivacyAllowlist.filterNonSDKProperties([:]).isEmpty)
    }

    @Test(
        "the three person-payload $ keys are dropped despite the $-prefix carve-out",
        arguments: ["$set", "$set_once", "$groups"]
    )
    func personPayloadKeysAreDropped(key: String) {
        let filtered = AnalyticsPrivacyAllowlist.filterNonSDKProperties([
            key: ["email": "dj@wxyc.org"],
            "$process_person_profile": false,
            "method": "otp",
        ])

        #expect(filtered[key] == nil)
        // The exclusion is surgical: it must not cost the flag the whole
        // carve-out exists to protect, nor an ordinary allowlisted key.
        #expect(filtered["$process_person_profile"] as? Bool == false)
        #expect(filtered["method"] as? String == "otp")
    }

    @Test("person-payload keys are excluded by name, never by inspecting the value")
    func personPayloadKeysAreDroppedByNameNotByValue() {
        // A nested dictionary's contents are `Any` and unknowable, so `$set`
        // carrying something innocuous today is not evidence about tomorrow.
        let filtered = AnalyticsPrivacyAllowlist.filterNonSDKProperties([
            "$set": ["favorite_bin": "heavy"],
        ])

        #expect(filtered.isEmpty)
    }

    /// The shape is the pinned posthog-ios 3.69.10's
    /// `PostHogExceptionProcessor`: `type`/`value`/`module`/`thread_id`, a
    /// `mechanism` of `type`/`handled`/`synthetic`, and a `stacktrace`. It has
    /// no `desc`/`data` like Sentry's mechanism, so every string leaf is
    /// scrubbed rather than a list of named fields.
    @Test("a URL's query and fragment inside $exception_list are scrubbed at every depth")
    func exceptionListUrlsAreScrubbed() throws {
        let filtered = AnalyticsPrivacyAllowlist.filterNonSDKProperties([
            "$exception_list": [[
                "type": "NSURLErrorDomain",
                "value": "failed: https://api.wxyc.org/library/search?artist=Juana%20Molina#top, retry",
                "mechanism": ["type": "generic", "handled": true, "synthetic": true],
                "stacktrace": ["frames": [["function": "load https://wxyc.org/a?token=abc"]]],
                "thread_id": 1,
            ] as [String: Any]],
        ])

        let exception = try #require((filtered["$exception_list"] as? [[String: Any]])?.first)
        #expect(exception["value"] as? String == "failed: https://api.wxyc.org/library/search, retry")
        let frames = (exception["stacktrace"] as? [String: Any])?["frames"] as? [[String: Any]]
        #expect(frames?.first?["function"] as? String == "load https://wxyc.org/a")
        // Non-string leaves and query-free strings are untouched.
        #expect(exception["type"] as? String == "NSURLErrorDomain")
        #expect(exception["thread_id"] as? Int == 1)
        #expect((exception["mechanism"] as? [String: Any])?["handled"] as? Bool == true)
    }

    @Test("other $-prefixed keys are not rewritten, even when their value holds a URL")
    func otherDollarKeysAreUnchanged() {
        let filtered = AnalyticsPrivacyAllowlist.filterNonSDKProperties([
            "$current_url": "https://dj.wxyc.org/x?y=1",
        ])

        #expect(filtered["$current_url"] as? String == "https://dj.wxyc.org/x?y=1")
    }

    @Test("no person-payload key is also an allowlisted or SDK-lifecycle key")
    func personPayloadKeysDoNotOverlapTheAllowlists() {
        // If one ever did, the exclusion above would silently start dropping a
        // key the catalog depends on.
        #expect(AnalyticsPrivacyAllowlist.personPayloadKeys
            .isDisjoint(with: AnalyticsPrivacyAllowlist.allowedKeys))
        #expect(AnalyticsPrivacyAllowlist.personPayloadKeys
            .isDisjoint(with: AnalyticsPrivacyAllowlist.sdkLifecycleKeys))
    }
}

@Suite("TelemetryBootstrap.isRunningUnitTests")
struct AnalyticsTestHostGuardTests {
    // The guard exists because `WXYCDJTests` is a host-app bundle, so
    // `AppDelegate.init()` -- and therefore `startAnalytics()` -- runs before
    // any test. Without it, every CI run emits SDK lifecycle events into
    // dj-site's production project.
    @Test("the runner's environment marker is detected")
    func detectsTestRunnerEnvironment() {
        #expect(TelemetryBootstrap.isRunningUnitTests(
            environment: ["XCTestConfigurationFilePath": "/tmp/Session.xctestconfiguration"]))
    }

    @Test("an app-launch environment is not mistaken for a test run")
    func doesNotFalsePositiveOnAppLaunch() {
        #expect(!TelemetryBootstrap.isRunningUnitTests(environment: [:]))
        #expect(!TelemetryBootstrap.isRunningUnitTests(environment: ["HOME": "/var/mobile"]))
    }

    @Test("this process really is a test run, so the production start is skipped")
    func thisProcessIsDetectedAsATestRun() {
        // Belt-and-braces against the parameterized form above passing while
        // the real call site reads something else: assert the live environment.
        #expect(TelemetryBootstrap.isRunningUnitTests(
            environment: ProcessInfo.processInfo.environment))
    }
}
