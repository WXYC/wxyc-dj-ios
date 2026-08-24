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
        // `type(of: event).name` reaches the concrete type's `static var` from
        // inside an opaque-parameter body just fine -- `SpyAnalytics` does the
        // same thing. (An earlier version routed this through a private
        // generic `static func` on the theory that `some AnalyticsEvent`
        // erased the concrete type here. It does not.)
        //
        // `build_type` is deliberately NOT stamped here: it belongs on *every*
        // event, and the SDK emits its own application-lifecycle events
        // directly, bypassing this conformer entirely. The stamp therefore
        // lives in `TelemetryBootstrap.filterAnalyticsEvent(_:)`, the
        // `beforeSend` hook every event really does pass through.
        PostHogSDK.shared.capture(
            type(of: event).name,
            properties: event.properties.mapValues(\.wireValue)
        )
    }
}
