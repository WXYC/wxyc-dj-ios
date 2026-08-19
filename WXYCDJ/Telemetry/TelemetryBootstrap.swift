//
//  TelemetryBootstrap.swift
//  WXYCDJ
//
//  Starts the Sentry SDK (issue #106). Called at the top of
//  AppDelegate.init(), before AppDependencies is constructed -- the
//  composition root's store-open failures (SQLite unavailable -> degraded
//  catalog/bin features) are exactly the silent field failure this exists to
//  see, so telemetry has to be live before anything in AppDependencies can
//  fail.
//
//  Concurrency spike, resolved (see git history for the original spike
//  commit): a bare `import Sentry` is sufficient here. sentry-cocoa's ObjC
//  headers already annotate `SentryOptions.beforeSend` / `.beforeBreadcrumb`
//  as `NS_SWIFT_SENDABLE` (the same fact wxyc-ios-64/WXYC/iOS/WXYCApp.swift
//  notes for `tracesSampler`), so a Swift closure literal assigned to either
//  property type-checks under this project's `SWIFT_STRICT_CONCURRENCY:
//  complete` with no `@preconcurrency`, no explicit `@Sendable`, and no
//  `nonisolated(unsafe)` needed anywhere in this file. Verified with
//  `xcodebuild build` against this exact target.
//
//  Created by Jake Bromberg on 08/19/26.
//  Copyright © 2026 WXYC. All rights reserved.
//

import Sentry
import WXYCAPI

enum TelemetryBootstrap {
    /// Placeholder DSN. The Sentry project for this app doesn't exist yet
    /// (blocked on an org permission) -- syntactically valid so
    /// `SentrySDK.start` doesn't reject it outright, but not a real
    /// destination. A DSN is a publishable client identifier, not a secret,
    /// so there's no plumbing concern in replacing it -- just don't ship
    /// this literal.
    // TODO(#106): replace with the real DSN once the Sentry project exists.
    private static let placeholderDSN = "https://0000000000000000000000000000@o0.ingest.sentry.io/0"

    /// Starts the SDK with the production DSN. The sole production call
    /// site is `AppDelegate.init()`.
    static func start() {
        start(dsn: placeholderDSN)
    }

    /// Starts the SDK against `dsn`. Split from ``start()`` so a test can
    /// exercise this exact option set -- privacy contract, sample rates, the
    /// scrub pipeline -- against a DSN of its own, never the placeholder
    /// above. See ``debugCaptureSerializedEvent(for:dsn:breadcrumb:via:)``.
    static func start(dsn: String) {
        SentrySDK.start { options in
            options.dsn = dsn

            // Unset, the SDK defaults this to "production" -- so every
            // Simulator run and every Xcode launch would file under real DJ
            // traffic. Computed rather than hardcoded per configuration
            // because Debug vs. TestFlight vs. App Store can't all be told
            // apart at compile time; see BuildEnvironment.
            options.environment = BuildEnvironment.current.rawValue

            // --- Privacy contract (issue #106) ---
            // Unlike wxyc-ios-64's anonymous listeners, DJ-app users are
            // signed in with real identities (usernames, emails, DJ ids,
            // JWTs), so these have to hold by construction. Stated
            // explicitly, matching the SDK's current defaults, so a future
            // SDK version flipping a default can't silently widen
            // collection without this file changing too.
            options.sendDefaultPii = false
            options.attachScreenshot = false
            options.attachViewHierarchy = false
            options.sessionReplay.sessionSampleRate = 0
            options.sessionReplay.onErrorSampleRate = 0

            // Deliberate departure from wxyc-ios-64's 0.05: the mandate here
            // is error reporting, not performance tracing, and tracing adds
            // a URL-carrying span surface (each span can capture a request
            // URL) for no benefit this issue asked for.
            options.tracesSampleRate = 0

            // This app *by design* fails requests and falls back to the
            // on-device catalog clone (issues #58/#81) -- auto-capturing
            // every failed HTTP request would turn expected offline
            // behavior into event spam, the same lesson wxyc-ios-64 learned
            // from stream-server 503s during outages.
            options.enableCaptureFailedRequests = false

            options.enableAutoSessionTracking = true
            options.enableAppHangTrackingV2 = true
            // wxyc-ios-64 measured non-fully-blocking hangs fragmenting into
            // noise over 30 days (1207 events -> 68 issues, 40 of them
            // holding a single event). V2 can tell a fully-blocking hang
            // (main thread stuck, no frame rendered) from one that merely
            // delayed a frame; dropping the latter before an event is even
            // created is what keeps that noise out.
            options.enableReportNonFullyBlockingAppHangs = false

            // Dozens of devices, not millions of listeners -- no reason to
            // sample down from full coverage.
            options.sampleRate = 1.0

            options.beforeBreadcrumb = { breadcrumb in
                TelemetryBootstrap.scrub(breadcrumb)
            }

            options.beforeSend = { event in
                let scrubbed = TelemetryBootstrap.scrub(event)
                #if DEBUG
                TelemetryBootstrap.lastSerializedEvent = scrubbed.serialize()
                #endif
                return scrubbed
            }

            // No fingerprinting here: wxyc-ios-64 measured client
            // fingerprints degenerating to a single bucket on
            // unsymbolicated Release frames (dSYM upload is a follow-up to
            // this issue, not yet wired). Custom grouping belongs to
            // Sentry's server-side Stack Trace Rules once that lands, not to
            // a client `beforeSend`.
        }
    }

    // MARK: - Scrub adapters

    /// Thin adapter over `TelemetryPrivacyScrub`: strips the query/fragment
    /// from every URL-bearing value on a breadcrumb before it's buffered.
    /// `message` and `data` are the two places an http breadcrumb (the kind
    /// issue #106's privacy contract is worried about) carries a URL --
    /// `data` structurally (a `"url"` entry among others), `message`
    /// sometimes as free text that embeds one.
    private static func scrub(_ breadcrumb: Breadcrumb) -> Breadcrumb {
        if let message = breadcrumb.message {
            breadcrumb.message = TelemetryPrivacyScrub.scrubEmbeddedURLs(in: message)
        }
        if let data = breadcrumb.data {
            breadcrumb.data = TelemetryPrivacyScrub.scrub(data)
        }
        return breadcrumb
    }

    /// Thin adapter over `TelemetryPrivacyScrub`: re-applies the same scrub
    /// to everything on the finished event that can carry a URL, as defense
    /// in depth beside ``scrub(_:)-breadcrumb``'s per-breadcrumb pass --
    /// `beforeBreadcrumb` is the only intended path a breadcrumb takes into
    /// the buffer, but re-scrubbing here means a breadcrumb added by some
    /// future path that bypasses it (an SDK-internal integration, a
    /// build-time SDK upgrade) still can't ship a query string.
    ///
    /// `event.request?.url` and `event.context`/`.breadcrumbs` are proper
    /// structured fields, so `TelemetryPrivacyScrub.scrub(_:)` (the
    /// whole-value walk) is the right tool. `exception.value` and
    /// `exception.mechanism?.desc` are different: sentry-cocoa builds both
    /// from `NSError.description`, which for a curated error or a bridged
    /// `URLError` alike renders the *entire* userInfo dictionary inline as
    /// free text -- so a query-carrying URL shows up there as a substring of
    /// a much longer string, never as the whole field. That is exactly what
    /// `scrubEmbeddedURLs(in:)` is for; see its doc comment.
    private static func scrub(_ event: Event) -> Event {
        if let urlString = event.request?.url {
            event.request?.url = URLScrubbing.scrub(urlString)
        }
        if let breadcrumbs = event.breadcrumbs {
            for breadcrumb in breadcrumbs {
                _ = scrub(breadcrumb)
            }
        }
        if let context = event.context {
            event.context = context.mapValues { TelemetryPrivacyScrub.scrub($0) }
        }
        for exception in event.exceptions ?? [] {
            exception.value = TelemetryPrivacyScrub.scrubEmbeddedURLs(in: exception.value)
            if let desc = exception.mechanism?.desc {
                exception.mechanism?.desc = TelemetryPrivacyScrub.scrubEmbeddedURLs(in: desc)
            }
            if let data = exception.mechanism?.data {
                exception.mechanism?.data = TelemetryPrivacyScrub.scrub(data)
            }
        }
        return event
    }

    #if DEBUG
    // MARK: - Test hook

    /// The most recent event `beforeSend` produced, after scrubbing,
    /// serialized to a plain `[String: Any]` via `Event.serialize()`.
    ///
    /// `#if DEBUG`-only, and read/written from this file alone. `Sentry`
    /// runs `beforeSend` synchronously as part of `capture(error:)`
    /// (verified against sentry-cocoa's `SentryClient.m`: `prepareEvent:`
    /// calls `options.beforeSend` inline on the calling thread, with no
    /// `dispatch_async` anywhere in the call chain from
    /// `SentrySDKInternal.captureError:withScopeBlock:` down to it) -- so a
    /// caller on the same thread that invoked `capture` can read this
    /// immediately afterward with no wait/semaphore needed.
    fileprivate nonisolated(unsafe) static var lastSerializedEvent: [String: Any]?

    /// Test-only hook (issue #106): starts the SDK against `dsn` with this
    /// file's real option set -- the same privacy contract and scrub
    /// pipeline production uses -- optionally records a breadcrumb, reports
    /// `error` through `reporter`, and returns the resulting event's
    /// serialized form.
    ///
    /// Returns plain Foundation (`[String: Any]`), not a `SentryEvent`, on
    /// purpose: `@testable import WXYCDJ` does not re-export the `Sentry`
    /// module, so WXYCDJTests can't name a Sentry type even under
    /// `@testable`. That is also why this app never links `Sentry` into the
    /// test target (see project.yml's Sentry package comment) -- this hook
    /// is the one seam the test bundle reaches through instead.
    ///
    /// - Parameters:
    ///   - error: The error to report, typically a `URLError` or a
    ///     message-bearing package error (`AuthError`/`APIError`).
    ///   - dsn: A test DSN -- never ``placeholderDSN`` or a real one.
    ///   - breadcrumb: Configures a `Breadcrumb` (level/category defaulted
    ///     to `.info`/`"http"`) to record before `error` is reported, so a
    ///     test can exercise the breadcrumb scrub path alongside the error
    ///     path in one captured event.
    ///   - reporter: Defaults to a real ``SentryErrorReporter`` so the
    ///     curated-`NSError` classification runs exactly as production does;
    ///     overridable for a test that wants to bypass it.
    static func debugCaptureSerializedEvent(
        for error: any Error,
        dsn: String,
        breadcrumb: ((Breadcrumb) -> Void)? = nil,
        via reporter: any ErrorReporter = SentryErrorReporter()
    ) -> [String: Any]? {
        lastSerializedEvent = nil
        start(dsn: dsn)

        if let breadcrumb {
            let crumb = Breadcrumb(level: .info, category: "http")
            breadcrumb(crumb)
            SentrySDK.addBreadcrumb(crumb)
        }

        reporter.report(error, context: "debugCaptureSerializedEvent")
        return lastSerializedEvent
    }
    #endif
}
