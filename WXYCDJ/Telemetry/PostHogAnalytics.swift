//
//  PostHogAnalytics.swift
//  WXYCDJ
//
//  The real Analytics conformer (issue #108) -- the one PostHog-importing
//  piece of this app's product-analytics seam, besides TelemetryBootstrap's
//  SDK start. Kept in its own file, separate from Analytics.swift's
//  protocol/AnalyticsPropertyValue/allowlist logic, precisely so that
//  everything *else* in Telemetry/ stays free of the PostHog import this app
//  deliberately never hands to WXYCDJTests (see Analytics.swift's header
//  and project.yml's PostHog package comment).
//
//  Created by Jake Bromberg on 08/24/26.
//  Copyright © 2026 WXYC. All rights reserved.
//

import PostHog

/// Records events to PostHog.
///
/// Holds no stored state of its own -- `PostHogSDK.shared` is the SDK's own
/// internally-synchronized singleton (guarded by its own locks; see
/// `PostHogSDK.swift`'s `setupLock`/`optOutLock`/etc.) -- so this conforms
/// to `Sendable` trivially, the same shape `SentryErrorReporter` uses for
/// its SDK.
struct PostHogAnalytics: Analytics {
    func capture(_ event: some AnalyticsEvent) {
        Self.capture(event)
    }

    /// The actual capture, factored out as a generic static function so
    /// `E.name` (a `static var` on the concrete event type) is available --
    /// `some AnalyticsEvent`'s opaque-parameter sugar erases the concrete
    /// type inside `capture(_:)`'s body otherwise.
    private static func capture<E: AnalyticsEvent>(_ event: E) {
        var properties = event.properties.mapValues(\.wireValue)
        // Every event carries this so a Debug-simulator run during
        // development can never dominate the ~dozens-of-real-DJs dataset --
        // PostHog has no Sentry-style `environment` concept, so without an
        // explicit dimension every launch under Xcode lands in the same
        // bucket as production traffic. `build_type` is in
        // AnalyticsPrivacyAllowlist.allowedKeys precisely because it's
        // stamped here rather than carried by any individual event's own
        // `properties`.
        properties["build_type"] = BuildEnvironment.current.rawValue
        PostHogSDK.shared.capture(E.name, properties: properties)
    }
}
