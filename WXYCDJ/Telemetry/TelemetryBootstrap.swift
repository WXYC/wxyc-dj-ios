//
//  TelemetryBootstrap.swift
//  WXYCDJ
//
//  Starts the Sentry SDK (issue #106) and the PostHog SDK (issue #108).
//  `start()` is called at the top of AppDelegate.init(), before
//  AppDependencies is constructed -- the composition root's store-open
//  failures (SQLite unavailable -> degraded catalog/bin features) are
//  exactly the silent field failure Sentry exists to see, so telemetry has
//  to be live before anything in AppDependencies can fail. `startAnalytics()`
//  is called right after -- see its own doc comment for why it's a second
//  call rather than folded into `start()`.
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
//  PostHog's `BeforeSendBlock` typealias (`(PostHogEvent) -> PostHogEvent?`)
//  is, unlike Sentry's, **not** annotated `@Sendable` -- `filterAnalyticsEvent`
//  below is passed to `setBeforeSend([...])` as a bare static-function value
//  (no closure literal, so nothing is captured) for exactly that reason;
//  spiked and verified building under this exact `SWIFT_STRICT_CONCURRENCY:
//  complete` configuration before the rest of issue #108 was stacked on it.
//
//  Created by Jake Bromberg on 08/19/26.
//  Copyright © 2026 WXYC. All rights reserved.
//

import PostHog
import Sentry
import WXYCAPI

enum TelemetryBootstrap {
    /// The `wxyc-dj-ios` Sentry project (org `wxyc`).
    ///
    /// Hardcoded rather than plumbed through Info.plist or a remote config
    /// because a DSN is a **publishable client identifier, not a secret** --
    /// it authorizes writing events to one project and nothing else, and it
    /// ships inside the app binary regardless of where it's read from, so
    /// hiding it would buy nothing. Revisit only if key rotation becomes a
    /// real need.
    private static let productionDSN = "https://60002d6113d87b42210304e42bdd4d3d@o4510807758143488.ingest.us.sentry.io/4511938878111744"

    /// Starts the SDK with the production DSN. The sole production call
    /// site is `AppDelegate.init()`.
    static func start() {
        start(dsn: productionDSN)
    }

    /// Starts the SDK against `dsn`. Split from ``start()`` so a test can
    /// exercise this exact option set -- privacy contract, sample rates, the
    /// scrub pipeline -- against a DSN of its own, never the production one
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

    // MARK: - PostHog (issue #108)

    /// **dj-site's** PostHog project (444958, org `wxyc`) — this app shares it
    /// rather than getting one of its own.
    ///
    /// A deliberate exception to the org's one-project-per-surface convention,
    /// not a workaround for the free tier's six-project cap. dj-site *is* the
    /// web equivalent of this app: the same DJs doing the same jobs (library
    /// search, the bin) on a different surface. In separate projects, "do DJs
    /// reach for the phone or the desktop for library search?" is unanswerable;
    /// in one project it is a breakdown on `$lib`. Verified before deciding
    /// (2026-08-24): the project's trailing-30-day traffic is entirely
    /// `$lib = web`, so `$lib` separates the two surfaces cleanly, and it
    /// carries no `$identify` events, so anonymous iOS events aren't dropped
    /// into a pool of identified DJ profiles. See issue #108 for the rejected
    /// alternatives (the listener project; a separate environment, which would
    /// have been better but appears gated to a paid tier).
    ///
    /// **Standing constraint that comes with sharing:** dj-site's event names
    /// (`$pageview`, `$rageclick`, `web_vitals`, `$exception`, `csp_violation`,
    /// `login_post_redirect`, `login_server_bounce`, the five `sse_*`,
    /// `flowsheet_optimistic_replace_miss`) collide with none of this app's
    /// twelve. Keep it that way on both surfaces — a name reused across
    /// surfaces would put two schemas under one event, and `$lib` is a filter
    /// you have to remember to apply, not a guarantee.
    ///
    /// Hardcoded for exactly the reason ``productionDSN`` is: a project token
    /// is a **publishable client identifier, not a secret**. It authorizes
    /// writing events to one project and nothing else, it ships inside the app
    /// binary wherever it is read from, and this particular one is already
    /// public in dj-site's web bundle.
    private static let postHogAPIKey = "phc_Dhry3BxmF752J5UX4h7mQeHmUkVj3gzknZRFDQChL6DV"

    /// `https://us.i.posthog.com` per issue #108 -- every DJ is in Chapel
    /// Hill, so there's no EU-residency reason to point at
    /// `eu.i.posthog.com`, and this is also `PostHogConfig`'s own default
    /// host.
    private static let productionHost = "https://us.i.posthog.com"

    /// Starts PostHog with the production project token. The sole production
    /// call site is `AppDelegate.init()`, right after ``start()`` -- a
    /// second call rather than folded into that one because the two SDKs
    /// have unrelated failure modes worth keeping visibly separate (a PostHog
    /// startup problem must never affect whether Sentry starts, and vice
    /// versa).
    ///
    /// Note that **no IP-discarding option is set here, and none exists.**
    /// Privacy contract item 3 (`$ip` dropped at ingest, no GeoIP enrichment)
    /// is `anonymize_ips`, a **project-wide server-side setting** on project
    /// 444958 — there is no client-side equivalent, so this is the one item of
    /// the contract the app cannot hold by construction. See ADR 0007 and
    /// CLAUDE.md for what flipping it costs dj-site and why that is safe.
    static func startAnalytics() {
        // `WXYCDJTests` is a host-app bundle (`TEST_HOST` points at
        // `WXYCDJ.app/WXYCDJ`), so `@main WXYCDJApp` -> `AppDelegate.init()`
        // runs before any test does. Without this guard every CI run and every
        // local `xcodebuild test` starts the real SDK against the production
        // token and emits `Application Opened` / `Application Installed` into
        // dj-site's shared project -- `captureApplicationLifecycleEvents` is on,
        // and those events are emitted by the SDK itself, so they bypass
        // `PostHogAnalytics` and the `NoOpAnalytics` default that keeps
        // app-authored events out of tests. `build_type` would mark them
        // `development`, i.e. indistinguishable from a real developer build.
        //
        // The tests that genuinely need a started SDK
        // (`PostHogPrivacyPipelineTests`) call
        // `debugCaptureAnalyticsEventProperties(_:apiKey:host:)` with their own
        // test key, so nothing is lost by skipping the production start here.
        guard !isRunningUnitTests(environment: ProcessInfo.processInfo.environment) else { return }
        startAnalytics(apiKey: postHogAPIKey, host: productionHost)
    }

    /// Whether this process was launched by the test runner.
    ///
    /// Takes the environment as a **parameter** rather than reading
    /// `ProcessInfo` directly, for the same reason
    /// `BuildEnvironment.classify(receiptURL:)` takes its URL: the predicate is
    /// then testable from a bundle that is *itself* always running under the
    /// test runner, where reading the real environment could only ever return
    /// `true`. `XCTestConfigurationFilePath` is set by the runner for Swift
    /// Testing bundles too -- the name is historical, not a statement about
    /// which framework is in use.
    static func isRunningUnitTests(environment: [String: String]) -> Bool {
        environment["XCTestConfigurationFilePath"] != nil
    }

    /// Starts PostHog against `apiKey`/`host`. Split from ``startAnalytics()``
    /// the same way ``start(dsn:)`` is split from ``start()`` -- so a test
    /// (or the `#if DEBUG` hook below) can exercise this exact option set
    /// against a project of its own, never the production token above.
    static func startAnalytics(apiKey: String, host: String) {
        PostHogSDK.shared.setup(makeAnalyticsConfig(apiKey: apiKey, host: host))
    }

    /// Builds the one `PostHogConfig` behind ``startAnalytics(apiKey:host:)``,
    /// which is the single path both production and the `#if DEBUG` belt-test
    /// hook take -- so the option set under test is byte-for-byte the one that
    /// ships.
    private static func makeAnalyticsConfig(apiKey: String, host: String) -> PostHogConfig {
        let config = PostHogConfig(projectToken: apiKey, host: host)

        // Free `Application Installed`/`Application Updated`/`Application
        // Opened` events with no PII -- worth the SDK default staying on.
        // Their own non-`$` properties (`version`, `build`, `previous_version`,
        // `previous_build`, `from_background`) reach the wire because
        // AnalyticsPrivacyAllowlist.sdkLifecycleKeys names them explicitly;
        // without that they'd survive as bare event names with the payload
        // that makes them worth keeping stripped off.
        config.captureApplicationLifecycleEvents = true
        // This app is entirely SwiftUI; the UIViewController-swizzling
        // `$screen` autocapture this flag drives would capture nothing
        // useful and its default is `true`, so it's turned off explicitly
        // rather than left to happen to be irrelevant.
        config.captureScreenViews = false
        // UIKit element-interaction autocapture -- already `false` by
        // default, stated explicitly so a future SDK version flipping the
        // default can't silently turn it on, matching ADR 0007's rule for
        // Sentry's six privacy options.
        config.captureElementInteractions = false
        // Rage-click autocapture -- a SECOND, INDEPENDENT gate, and the one
        // that actually matters. `getIntegrations()` reads
        // `captureElementInteractions` and `rageClickConfig.enabled` in two
        // separate `if`s (PostHogConfig.swift:544-551 in the pinned 3.69.10),
        // so turning the line above off does NOT disable this one, and its
        // default is `true`. It swizzles `UIApplication.sendEvent(_:)` and
        // hit-tests `UIWindow`, so "this app is entirely SwiftUI" is not an
        // exemption either -- the SDK ships a SwiftUI opt-out modifier
        // precisely because SwiftUI is a supported surface.
        //
        // Load-bearing for the privacy contract, not hygiene: `$rageclick`
        // carries `$elements_chain`, which serializes node text from button
        // titles and text-field values/placeholders, and the SDK's
        // `sanitizeText` only trims whitespace (its own source carries a
        // `TODO: Filter out or obfuscate strings that look like sensitive
        // data`). Because every one of those keys is `$`-prefixed, the
        // allowlist's carve-out would pass the whole payload through
        // untouched. That is a direct hit on ADR 0007's never-collect floor
        // -- free text the DJ typed into library search -- reached through a
        // door the typed-event layer cannot see. Off, explicitly.
        config.rageClickConfig.enabled = false

        // --- Privacy contract (issue #108, extending ADR 0007) ---
        // NOT `.identifiedOnly` (the SDK default). `.identifiedOnly` computes
        // `hasPersonProcessing()` as false only while `isIdentified() ==
        // false` AND `isPersonProcessing() == false` -- and the second is a
        // sticky, persisted flag that `identify`/`alias`/`group`/
        // `setPersonPropertiesForFlags`, and `capture(...)` with any
        // non-empty `userProperties`/`userPropertiesSetOnce`/`groups`, all
        // set (verified against PostHogSDK.swift's `requirePersonProcessing`).
        // `.identifiedOnly` would make anonymity a promise held across five
        // call paths by a comment; `.never` forces
        // `$process_person_profile: false` unconditionally and turns
        // `identify` into a logged no-op. No `PostHogSDK.identify(...)` call
        // exists anywhere in this app -- see CLAUDE.md's Telemetry section.
        config.personProfiles = .never
        // iOS-only SDK features this app has no use for and does not want
        // running: session replay, and mobile surveys (`surveys` defaults to
        // `true` -- unlike the other three, turning this off is not merely
        // restating a default).
        config.sessionReplay = false
        config.surveys = false
        // Sentry owns errors (issue #106); PostHog's own crash/exception
        // autocapture stays off explicitly rather than resting on its
        // already-`false` default, so a future SDK version can't quietly
        // stand up a second, uncurated error-reporting pipeline alongside
        // ADR 0007's. This local flag is authoritative: `getIntegrations()`
        // only installs PostHogErrorTrackingAutoCaptureIntegration when it's
        // true, so the SDK's *remote* `errorTracking.autocaptureExceptions`
        // config can't switch it back on.
        config.errorTrackingConfig.autoCapture = false
        // Feature flags are explicitly out of scope for issue #108 and this
        // app reads none -- but the SDK default is `true`, which spends a
        // `/flags` round trip (plus a handful of cache writes) at setup and on
        // every foreground to fetch an answer nothing consults. Off.
        config.preloadFeatureFlags = false

        // The runtime backstop behind the typed AnalyticsEvent catalog: a
        // bare static-function value (no closure literal), so nothing is
        // captured -- see this file's header for why that's load-bearing
        // under BeforeSendBlock's non-`@Sendable` typealias.
        config.setBeforeSend([filterAnalyticsEvent])

        return config
    }

    /// The `beforeSend` filter every PostHog event passes through: applies
    /// ``AnalyticsPrivacyAllowlist/filterNonSDKProperties(_:)`` to the fully
    /// merged property dict, stamps `build_type`, then (DEBUG only) records
    /// the result for ``debugCaptureAnalyticsEventProperties(_:apiKey:host:)``
    /// to return. `nonisolated` and captures nothing, per this file's header.
    ///
    /// **`build_type` is stamped here, not in `PostHogAnalytics`, and that is
    /// the point.** PostHog has no Sentry-style `environment` concept, so
    /// without a build dimension every Debug-simulator run during development
    /// lands in the same dataset as the ~dozens of real DJs and dominates it.
    /// `PostHogAnalytics.capture` only sees events *this app* authors --
    /// `captureApplicationLifecycleEvents = true` means the SDK emits
    /// `Application Opened`/`Installed`/`Updated`/`Backgrounded` by calling
    /// `PostHogSDK.capture` directly, bypassing the conformer. `Application
    /// Opened` is both the canonical launch/retention event *and* the one a
    /// developer generates dozens of times a day, i.e. exactly where the
    /// pollution `build_type` exists to make filterable is worst. `beforeSend`
    /// is the one genuine chokepoint: verified in the pinned SDK, every
    /// capture path runs `captureInternal` → `buildEvent` → `runBeforeSend`.
    ///
    /// Stamped *before* the filter, so the allowlist is genuinely total: every
    /// key on the outgoing event, this one included, has cleared
    /// ``AnalyticsPrivacyAllowlist``. An earlier version stamped it after, on
    /// the reasoning that the order shouldn't be misread as the allowlist
    /// vetting it -- but that bought a cosmetic clarification at the price of
    /// two things that were then simply false: `allowedKeys`'s own doc comment
    /// says `build_type` "has to clear this gate exactly like a typed property
    /// does," and `AnalyticsEventCatalogTests` asserts its membership. Neither
    /// had a mechanism behind it. `BuildEnvironment.current` is a `static let`,
    /// so this costs nothing per event.
    private static func filterAnalyticsEvent(_ event: PostHogEvent) -> PostHogEvent? {
        var properties = event.properties
        properties["build_type"] = BuildEnvironment.current.rawValue
        event.properties = AnalyticsPrivacyAllowlist.filterNonSDKProperties(properties)
        #if DEBUG
        TelemetryBootstrap.lastAnalyticsEventProperties = event.properties
        #endif
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
    ///   - dsn: A test DSN -- never ``productionDSN`` or a real one.
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

    // MARK: - PostHog test hook (issue #108)

    /// The most recent event's properties, after ``filterAnalyticsEvent(_:)``
    /// ran -- plain Foundation (`[String: Any]`), never a `PostHogEvent`.
    /// `@testable import WXYCDJ` does not re-export the `PostHog` module, so
    /// WXYCDJTests can't name a PostHog type even under `@testable` -- the
    /// same reason this app never links `PostHog` into the test target (see
    /// project.yml's PostHog package comment). This hook is the one seam the
    /// test bundle reaches through instead.
    fileprivate nonisolated(unsafe) static var lastAnalyticsEventProperties: [String: Any]?

    /// Test-only hook (issue #108): captures `event` through a real
    /// `PostHogAnalytics()` against a fresh SDK instance configured with
    /// this file's real option set -- the same privacy contract and
    /// `beforeSend` filter production uses -- and returns the resulting
    /// event's properties.
    ///
    /// `close()` then `setup(_:)` rather than `setup(_:)` alone: PostHog logs
    /// a warning and no-ops on a second `setup(_:)` call to an instance
    /// that's already enabled (verified against `PostHogSDK.swift`), unlike
    /// `SentrySDK.start`, which is freely re-callable -- so a suite with more
    /// than one test in it needs the explicit teardown. `close()` on a
    /// never-set-up instance is itself a documented no-op, so the first call
    /// in a process is safe too.
    ///
    /// - Parameters:
    ///   - event: The event to capture.
    ///   - apiKey: A test project token -- never ``postHogAPIKey`` or a real
    ///     one. Defaults to a syntactically-valid placeholder so
    ///     `PostHogConfig`'s empty-token guard doesn't itself disable the SDK.
    ///   - host: Defaults to the discard port on loopback, deliberately **not**
    ///     ``productionHost``. Nothing this hook asserts depends on the host --
    ///     `beforeSend` runs inline, long before anything is flushed -- but
    ///     `setup(_:)` does kick off real background requests (remote config,
    ///     and the queue's flush timer), so a production default would have CI
    ///     opening connections to PostHog's live ingest endpoint on every run,
    ///     with a bogus token, for no assertion's benefit. Loopback fails those
    ///     instantly instead.
    static func debugCaptureAnalyticsEventProperties(
        _ event: some AnalyticsEvent,
        apiKey: String = "phc_test_00000000000000000000000000000000",
        host: String = "http://127.0.0.1:9"
    ) -> [String: Any]? {
        lastAnalyticsEventProperties = nil
        PostHogSDK.shared.close()
        startAnalytics(apiKey: apiKey, host: host)

        PostHogAnalytics().capture(event)
        return lastAnalyticsEventProperties
    }
    #endif
}
