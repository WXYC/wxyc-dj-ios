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
import WXYCAPI
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

/// Closed vocabulary of exactly one case, carrying a realistic-looking but
/// obviously synthetic DJ email -- not a real WXYC DJ, and unrelated to the
/// WXYC-representative-artist fixture pool, since this stands in for a PII
/// leak rather than example data. Exists purely to give
/// ``RogueIdentifyingTestEvent`` a value that *looks like* what a real leak
/// would look like, rather than an inert `.int`.
private enum RogueIdentifyingValue: String, AnalyticsEnum {
    case marker = "dj.kendra87@wxyc-test.example"
}

/// A second rogue event, carrying its identifying marker as an
/// `.enumString` value under an unallowlisted key, alongside one genuinely
/// allowlisted property. Issue #117: the four-named-key belt test could only
/// ever prove four specific fields were clean, so it said nothing about the
/// rest of the merged dict.
///
/// `result_count` is here as a **positive identity assertion**, not as
/// payload. `TelemetryBootstrap.lastAnalyticsEventProperties` holds whatever
/// last cleared `beforeSend`, and `captureApplicationLifecycleEvents = true`
/// routes the SDK's own `Application Opened`/`Backgrounded` events through
/// that same hook -- so a purely negative test could read back a *lifecycle*
/// event's properties, find them non-empty and marker-free, and pass without
/// ever having looked at this event at all. Asserting a value only this
/// fixture emits is what rules that out, matching what the suite's other
/// three tests get for free by asserting `method` / `build_type` /
/// `$process_person_profile`.
private struct RogueIdentifyingTestEvent: AnalyticsEvent {
    static let name = "rogue_identifying_test_event"
    var properties: [String: AnalyticsPropertyValue] {
        [
            "not_on_any_allowlist": .enumString(RogueIdentifyingValue.marker),
            "result_count": .int(rogueIdentityWitness),
        ]
    }
}

/// An implausible value no real `SearchPerformedEvent` would carry, so
/// finding it proves the properties under assertion came from
/// ``RogueIdentifyingTestEvent`` and not from a lifecycle event that landed
/// in the hook afterwards.
private let rogueIdentityWitness = 987_654

/// The marker for the **positive control** below, kept distinct from
/// ``RogueIdentifyingValue`` so neither test can pass on the other's string.
private enum RogueSurvivingValue: String, AnalyticsEnum {
    case marker = "dj.marlon42@wxyc-test.example"
}

/// The positive control, and the fixture that makes the traversal test
/// non-vacuous. `filterNonSDKProperties` waves **every** `$`-prefixed key
/// through untouched (`key.hasPrefix("$") || allowedKeys.contains(key) ||
/// ...`, minus the three person-payload keys), and an `AnalyticsEvent`'s
/// `properties` dict is keyed by an unconstrained `String` -- so an
/// app-authored `$` key bypasses the allowlist entirely and reaches the
/// merged dict with its value intact. That is exactly the passthrough
/// surface the `$rageclick` leak lived on, and it is the only way a test
/// fixture can put a string *into* that surface, since the real `$` keys are
/// SDK-authored.
///
/// Without this control the traversal test could not fail for any reason
/// ``unallowlistedKeyIsDroppedEndToEnd`` doesn't already catch:
/// `filterNonSDKProperties` is a `Dictionary.filter`, which can only drop
/// keys and never rename one, so a marker riding an unallowlisted key is
/// always gone before the walk runs. Proving the walk *finds* a marker that
/// genuinely survives is what shows it observes live values rather than only
/// re-confirming that the filter dropped something.
private struct RogueSurvivingTestEvent: AnalyticsEvent {
    static let name = "rogue_surviving_test_event"
    var properties: [String: AnalyticsPropertyValue] {
        ["$rogue_passthrough": .enumString(RogueSurvivingValue.marker)]
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

    /// The **positive control** for the traversal, and the reason the test
    /// below is not vacuous. See ``RogueSurvivingTestEvent`` for why an
    /// app-authored `$`-prefixed key is the one way a fixture can put a
    /// string onto the passthrough surface `filterNonSDKProperties` waves
    /// through: the real `$` keys are SDK-authored, so nothing else a test
    /// can write reaches it.
    ///
    /// This asserts the walk **finds** that marker. Read together with the
    /// negative test below, the pair says something neither says alone: the
    /// traversal genuinely observes surviving values anywhere in the merged
    /// dict (this test), *and* a marker on an unallowlisted key is gone by
    /// the time it runs (the next test). Without this control the negative
    /// test could pass simply because the walk was broken.
    ///
    /// It also pins a fact worth knowing on its own: the allowlist is
    /// **not** a gate on `$`-prefixed keys, so an app event that names one
    /// bypasses it entirely. That is a deliberate carve-out (stripping `$`
    /// would take `$process_person_profile` and the whole SDK context with
    /// it), not an oversight -- but it is a carve-out no type prevents an
    /// event from walking through, which is why it is pinned here rather
    /// than left to a comment.
    @Test("the traversal finds a marker that genuinely survives the filter, on the $-prefixed passthrough surface")
    func traversalFindsAMarkerThatSurvivesTheFilter() throws {
        let properties = try #require(TelemetryBootstrap.debugCaptureAnalyticsEventProperties(
            RogueSurvivingTestEvent(),
            apiKey: Self.testAPIKey
        ))

        // The $-prefix carve-out let this key through, allowlist untouched.
        #expect(properties["$rogue_passthrough"] as? String == RogueSurvivingValue.marker.rawValue)

        let strings = SerializedValueStrings.allStrings(in: properties)
        #expect(
            strings.contains(RogueSurvivingValue.marker.rawValue),
            "the traversal missed a value that reached the merged dict -- it cannot prove absence if it cannot find presence"
        )
    }

    /// Issue #117: the three tests this suite had before this one
    /// (`processPersonProfileFlagIsFalse`,
    /// `realEventPropertiesSurviveWithBuildType`,
    /// `unallowlistedKeyIsDroppedEndToEnd`) only ever looked at four named
    /// keys — `$process_person_profile`, `method`, `build_type`,
    /// `not_on_any_allowlist` — which left the rest of the captured
    /// properties dict unobserved by any test. A full recursive walk is the
    /// only way to hold the real bar: nothing this app captures should carry
    /// a DJ-identifying string *anywhere* in the payload, not just under the
    /// keys a test happened to anticipate.
    ///
    /// **What this test does and does not prove, stated precisely, because an
    /// earlier version of this comment overstated it.** It does not catch a
    /// filter regression that "renamed rather than dropped" the key:
    /// `filterNonSDKProperties` is a `Dictionary.filter`, which can only drop
    /// keys, so that regression is structurally unreachable and claiming it
    /// was the same species of overclaim issue #117 exists to remove. What it
    /// does hold is the absence bar over the **whole** merged dict, keys as
    /// well as values -- so it would catch a future rewrite of the filter
    /// that is no longer a pure `filter`, an SDK minor that starts folding
    /// this value into a `$` key it authors, or a capture path that routes
    /// around `beforeSend`. The positive control above is what makes that a
    /// real assertion rather than a walk that finds nothing anywhere.
    @Test("no DJ-identifying string appears anywhere in the captured properties, not just under four named keys")
    func noDJIdentifyingStringAnywhereInProperties() throws {
        let properties = try #require(TelemetryBootstrap.debugCaptureAnalyticsEventProperties(
            RogueIdentifyingTestEvent(),
            apiKey: Self.testAPIKey
        ))

        // Positive identity assertion: proves these properties are this
        // fixture's and not a lifecycle event's -- see the fixture's doc
        // comment. Without it every assertion below is purely negative and a
        // substituted event would pass them all.
        #expect(properties["result_count"] as? Int == rogueIdentityWitness)

        let strings = SerializedValueStrings.allStrings(in: properties)
        // PostHog's own $-context ($app_version, $lib, ...) is still there.
        #expect(!strings.isEmpty)
        for string in strings {
            #expect(!string.contains(RogueIdentifyingValue.marker.rawValue), "leaked a DJ-identifying string in: \(string)")
        }
    }

    // MARK: - `$exception` (issue #233)

    /// A transport error whose `NSUnderlyingErrorKey` chain carries a URL with
    /// a query string and a free-text `NSDebugDescriptionErrorKey`: the two
    /// channels posthog-ios's exception processor reads and
    /// `TelemetryErrorClassification.curated` does not control. The URL
    /// scrub (issue #232) covers the first; only dropping the chain keeps the
    /// free-text description out.
    private static let leakyDescription = "request failed for dj.kendra87@wxyc-test.example"
    private static let queryString = "artist=Juana%20Molina"

    private static func urlBearingError() -> NSError {
        let underlying = NSError(
            domain: NSURLErrorDomain,
            code: NSURLErrorTimedOut,
            userInfo: [
                NSDebugDescriptionErrorKey: leakyDescription,
                NSURLErrorFailingURLStringErrorKey: "https://api.wxyc.org/library?\(queryString)"
            ]
        )
        return NSError(
            domain: NSURLErrorDomain,
            code: NSURLErrorNotConnectedToInternet,
            userInfo: [
                NSDebugDescriptionErrorKey: "\(leakyDescription) https://api.wxyc.org/library?\(queryString)",
                NSUnderlyingErrorKey: underlying
            ]
        )
    }

    @Test("no identity, free text or query string appears anywhere in a serialized $exception")
    func exceptionPayloadIsFreeOfIdentityAndQueryStrings() throws {
        let properties = try #require(TelemetryBootstrap.debugCaptureExceptionProperties(
            for: Self.urlBearingError(),
            context: "PostHogPrivacyPipelineTests",
            apiKey: Self.testAPIKey
        ))

        // Positive identity assertions: the properties are this exception's,
        // not a lifecycle event's, and the walk below has something to read.
        #expect(properties[AnalyticsPrivacyAllowlist.errorContextKey] as? String == "PostHogPrivacyPipelineTests")
        #expect(properties["$exception_list"] != nil)
        #expect(properties["$process_person_profile"] as? Bool == false)

        let strings = SerializedValueStrings.allStrings(in: properties)
        #expect(!strings.isEmpty)
        for string in strings {
            #expect(!string.contains("kendra87"), "leaked a DJ-identifying string in: \(string)")
            #expect(!string.contains("request failed"), "leaked a free-text description in: \(string)")
            #expect(!string.contains(Self.queryString), "leaked a query string in: \(string)")
        }
    }

    @Test("a curated AuthError reaches $exception without its server copy")
    func curatedErrorMessageDoesNotReachException() throws {
        let properties = try #require(TelemetryBootstrap.debugCaptureExceptionProperties(
            for: AuthError.rejected(message: "No account for dj.marlon42@wxyc-test.example"),
            context: "PostHogPrivacyPipelineTests",
            apiKey: Self.testAPIKey
        ))

        #expect(properties["$exception_list"] != nil)
        for string in SerializedValueStrings.allStrings(in: properties) {
            #expect(!string.contains("marlon42"), "leaked server copy in: \(string)")
        }
    }

    /// Issue #233 review: once the debug description is stripped, posthog-ios
    /// falls back to `localizedDescription`, which a native `NSError` (or a
    /// `CustomNSError`) builds from free text in `NSLocalizedDescriptionKey`.
    /// The allowlisted rebuild leaves `exception.value` as domain and code.
    @Test("free text in NSLocalizedDescriptionKey never reaches $exception")
    func localizedDescriptionDoesNotReachException() throws {
        let error = NSError(
            domain: "org.wxyc.dj.test",
            code: 42,
            userInfo: [
                NSLocalizedDescriptionKey: "Upload to https://api.wxyc.org/bins?\(Self.queryString) failed for dj.kendra87@wxyc-test.example"
            ]
        )

        let properties = try #require(TelemetryBootstrap.debugCaptureExceptionProperties(
            for: error,
            context: "PostHogPrivacyPipelineTests",
            apiKey: Self.testAPIKey
        ))

        let exception = try #require((properties["$exception_list"] as? [[String: Any]])?.first)
        #expect(exception["value"] as? String == "org.wxyc.dj.test (Code: 42)")
        for string in SerializedValueStrings.allStrings(in: properties) {
            #expect(!string.contains("kendra87"), "leaked an email in: \(string)")
            #expect(!string.contains("api.wxyc.org/bins"), "leaked a URL in: \(string)")
            #expect(!string.contains("Upload to"), "leaked free text in: \(string)")
        }
    }

    // MARK: - MetricKit hang diagnostics (issue #234)

    /// A hang fixture whose attributed frame names a binary with a URL-shaped
    /// name carrying a query string -- MetricKit never produces one, so the
    /// scrub is what has to hold if it ever does.
    private static let hangJSON = """
    {"callStackTree": {"callStacks": [{"threadAttributed": true, "callStackRootFrames": [
       {"binaryUUID": "AAAA", "offsetIntoBinaryTextSegment": 4096, "sampleCount": 1,
        "binaryName": "https://api.wxyc.org/bins?\(queryString)", "address": 4300000000}]}]},
     "diagnosticMetaData": {"appBuildVersion": "412"}}
    """

    @Test("a hang event keeps its non-$ properties through beforeSend and its string leaves are scrubbed")
    func hangEventKeepsPropertiesAndScrubsLeaves() throws {
        let event = try #require(MetricKitDiagnosticMapper.event(
            kind: .hang,
            json: Data(Self.hangJSON.utf8),
            appBinaryName: "WXYCDJ",
            period: DateInterval(start: Date(timeIntervalSince1970: 1_800_000_000), duration: 60),
            hangDurationMilliseconds: 4_200
        ))

        let properties = try #require(TelemetryBootstrap.debugCaptureDiagnosticProperties(event, apiKey: Self.testAPIKey))

        #expect(properties["source"] as? String == "metrickit")
        #expect(properties["diagnostic_kind"] as? String == "hang")
        #expect(properties["hang_duration_ms"] as? Int == 4_200)
        #expect(properties["diagnostic_app_build"] as? Int == 412)
        #expect(properties["diagnostic_period_start"] as? String == "2027-01-15T08:00:00Z")
        #expect(properties["$exception_list"] != nil)
        #expect(properties["$debug_images"] != nil)
        #expect(properties["$process_person_profile"] as? Bool == false)

        let strings = SerializedValueStrings.allStrings(in: properties)
        // Positive control: the URL's scheme, host and path survive, so the walk found the scrubbed leaf.
        #expect(strings.contains { $0.contains("api.wxyc.org/bins") })
        for string in strings {
            #expect(!string.contains(Self.queryString), "leaked a query string in: \(string)")
        }
    }

    // MARK: - MetricKit crash diagnostics (issue #238)

    /// A crash fixture whose crash-site frame names a URL-shaped binary and whose reason is free text:
    /// MetricKit never produces either, so the scrub and the closed namespace are what hold if it does.
    private static let crashJSON = """
    {"callStackTree": {"callStacks": [{"threadAttributed": true, "callStackRootFrames": [
       {"binaryUUID": "AAAA", "offsetIntoBinaryTextSegment": 4096, "sampleCount": 1,
        "binaryName": "https://api.wxyc.org/bins?\(queryString)", "address": 4300000000}]}]},
     "diagnosticMetaData": {"appBuildVersion": "412", "signal": 11, "exceptionType": 1, "exceptionCode": 0,
                            "terminationReason": "Namespace SIGNAL, Code 11 \(queryString)"}}
    """

    @Test("a crash event keeps source and diagnostic_kind through beforeSend and its string leaves are scrubbed")
    func crashEventKeepsPropertiesAndScrubsLeaves() throws {
        let event = try #require(MetricKitDiagnosticMapper.event(
            kind: .crash,
            json: Data(Self.crashJSON.utf8),
            appBinaryName: "WXYCDJ",
            period: DateInterval(start: Date(timeIntervalSince1970: 1_800_000_000), duration: 60)
        ))

        let properties = try #require(TelemetryBootstrap.debugCaptureDiagnosticProperties(event, apiKey: Self.testAPIKey))

        #expect(properties["source"] as? String == "metrickit")
        #expect(properties["diagnostic_kind"] as? String == "crash")
        #expect(properties["$exception_level"] as? String == "fatal")
        #expect(properties["termination_namespace"] as? String == "signal")
        #expect(properties["crash_signal"] as? Int == 11)
        #expect(properties["$exception_list"] != nil)
        #expect(properties["$debug_images"] != nil)
        #expect(properties["$process_person_profile"] as? Bool == false)

        let strings = SerializedValueStrings.allStrings(in: properties)
        // Positive control: the URL's scheme, host and path survive, so the walk found the scrubbed leaf.
        #expect(strings.contains { $0.contains("api.wxyc.org/bins") })
        for string in strings {
            #expect(!string.contains(Self.queryString), "leaked a query string in: \(string)")
        }
    }

    @Test("PostHog crash and exception autocapture stays off while Sentry's crash handler is installed")
    func errorAutoCaptureIsOff() {
        #expect(TelemetryBootstrap.debugErrorAutoCaptureEnabled() == false)
    }
}
