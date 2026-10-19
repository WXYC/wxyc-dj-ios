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

    /// Drops the two `userInfo` channels posthog-ios's exception processor
    /// reads that `TelemetryErrorClassification.curated` does not control:
    /// `NSDebugDescriptionErrorKey` becomes `exception.value`, and the
    /// `NSUnderlyingErrorKey` chain becomes one more entry in `$exception_list`
    /// each, with its own debug description. The URL scrub on that list
    /// (issue #232) strips query strings but cannot recognize free text, so
    /// the chain does not go to the SDK at all. Domain and code -- what makes
    /// a transport failure legible -- are kept, as is the rest of `userInfo`.
    static func sanitized(_ error: any Error) -> NSError {
        let nsError = error as NSError
        var userInfo = nsError.userInfo
        userInfo.removeValue(forKey: NSUnderlyingErrorKey)
        userInfo.removeValue(forKey: NSDebugDescriptionErrorKey)
        return NSError(domain: nsError.domain, code: nsError.code, userInfo: userInfo)
    }

    /// The properties merged into the `$exception` event: the context, and the
    /// extras nested under one key (an `.errorIdentity` flattened to
    /// `<key>.domain` / `<key>.code`, as the Sentry reporter does).
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
