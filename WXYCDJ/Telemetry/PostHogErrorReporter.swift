//
//  PostHogErrorReporter.swift
//  WXYCDJ
//
//  The second ErrorReporter conformer (issue #233): sends the curated error
//  to PostHog error tracking as an `$exception`, beside SentryErrorReporter
//  in a CompositeErrorReporter while Sentry is phased out. Like
//  PostHogAnalytics it is one of the few files that imports PostHog, so the
//  pure halves (`sanitized`, `properties`) are plain statics WXYCDJTests can
//  call under `@testable import WXYCDJ` without naming a PostHog type.
//
//  Created by Jake Bromberg on 10/19/26.
//  Copyright © 2026 WXYC. All rights reserved.
//

import Foundation
import PostHog

/// Reports errors to PostHog.
///
/// Holds no state -- `PostHogSDK.shared` is the SDK's own synchronized
/// singleton -- so it is trivially `Sendable`. A no-op until the SDK is
/// started, which is why test paths need no guard.
struct PostHogErrorReporter: ErrorReporter {
    func report(_ error: any Error, context: StaticString, extra: [String: TelemetryValue]) {
        // Curated first, for the reason SentryErrorReporter documents: a raw
        // AuthError/APIError would put a server's message in the headline.
        // `build_type` is stamped by TelemetryBootstrap's `beforeSend`, which
        // every capture path passes through, so it is not repeated here.
        let reported = Self.sanitized(TelemetryErrorClassification.curated(error))
        PostHogSDK.shared.captureException(reported, properties: Self.properties(context: context, extra: extra))
    }

    /// Sends a MetricKit diagnostic as an `$exception` (issue #234). A second
    /// entry point beside ``report(_:context:extra:)`` rather than a case of
    /// it: that one takes an `Error` and rebuilds it from domain and code, so
    /// it cannot carry hand-built frames. PostHog-only by design -- it is not
    /// on `ErrorReporter` or `CompositeErrorReporter`, because Sentry has its
    /// own hang tracking during the dual run. Fail-open like `report`: the SDK
    /// call neither throws nor blocks, and is a no-op until the SDK starts.
    /// The typed ``ExceptionEvent`` is the privacy contract; `beforeSend` is
    /// the backstop that scrubs its string leaves.
    func report(diagnostic: ExceptionEvent) {
        PostHogSDK.shared.capture(ExceptionEvent.name, properties: diagnostic.properties)
    }

    /// The `userInfo` keys ``sanitized(_:)`` carries over from the reported
    /// error. **Empty, and an allowlist rather than a denylist** (issue #233
    /// review): posthog-ios 3.69.10's `PostHogExceptionProcessor` reads
    /// exactly three things off an `NSError` -- `NSDebugDescriptionErrorKey`
    /// (becomes `exception.value`), `localizedDescription` (the fallback for
    /// `exception.value`, which a native `NSError` or a `CustomNSError`
    /// builds from free text in `NSLocalizedDescriptionKey` and its
    /// siblings), and the `NSUnderlyingErrorKey` chain (one more
    /// `$exception_list` entry each). Nothing else in `userInfo` is sent, so
    /// a key here buys nothing unless it feeds one of those channels -- and a
    /// key that does is a leak the #232 URL scrub cannot recognize. Adding a
    /// member is a privacy review, not a convenience.
    static let allowedUserInfoKeys: Set<String> = []

    /// Rebuilds `error` from its domain and code alone, plus any
    /// ``allowedUserInfoKeys``, and pins `NSDebugDescriptionErrorKey` to the
    /// domain so posthog-ios's `exception.value` reads `"<domain> (Code:
    /// <code>)"` rather than falling back to `localizedDescription`. Domain
    /// and code -- what makes a transport failure legible -- are a developer
    /// constant and an integer; no free text reaches the event.
    static func sanitized(_ error: any Error) -> NSError {
        let nsError = error as NSError
        var userInfo = nsError.userInfo.filter { key, _ in allowedUserInfoKeys.contains(key) }
        userInfo[NSDebugDescriptionErrorKey] = nsError.domain
        return NSError(domain: nsError.domain, code: nsError.code, userInfo: userInfo)
    }

    /// The properties merged into the `$exception` event: the context, and the
    /// extras nested under one key (an `.errorIdentity` flattened to
    /// `<key>.domain` / `<key>.code`, as the Sentry reporter does). Each
    /// flattened key must be on ``AnalyticsPrivacyAllowlist/errorExtraKeys``
    /// or `beforeSend` drops it.
    static func properties(context: StaticString, extra: [String: TelemetryValue]) -> [String: Any] {
        var properties: [String: Any] = [AnalyticsPrivacyAllowlist.errorContextKey: "\(context)"]
        var nested: [String: Any] = [:]
        for (key, value) in extra {
            switch value {
            case .int(let number):
                nested[key] = number
            case .bool(let flag):
                nested[key] = flag
            case .string(let text):
                nested[key] = "\(text)"
            case .errorIdentity(let domain, let code):
                nested["\(key).domain"] = domain
                nested["\(key).code"] = code
            }
        }
        if !nested.isEmpty {
            properties[AnalyticsPrivacyAllowlist.errorExtraKey] = nested
        }
        return properties
    }
}
