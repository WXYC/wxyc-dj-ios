//
//  AnalyticsPrivacyFilterTests.swift
//  WXYCDJTests
//
//  Pins the pure half of issue #108's runtime backstop --
//  `AnalyticsPrivacyAllowlist.filterNonSDKProperties(_:)` -- independent of
//  the real PostHog SDK: a `$`-prefixed key (PostHog's own context, plus the
//  `$process_person_profile` flag the `personProfiles = .never` contract item
//  depends on) survives untouched, and a non-allowlisted, non-`$` key is
//  dropped. The end-to-end version of the same guarantee, run through the
//  real started SDK, is `PostHogPrivacyPipelineTests`.
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
}
