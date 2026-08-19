//
//  TelemetryBootstrap.swift
//  WXYCDJ
//
//  Spike (issue #106): the smallest SentrySDK.start that exercises a
//  beforeSend and a beforeBreadcrumb closure under this project's exact
//  build configuration (Swift 6, SWIFT_STRICT_CONCURRENCY: complete). Those
//  hooks are ObjC callbacks the SDK isn't Sendable-audited for, so this file
//  exists to answer one question before the real privacy-scrub logic stacks
//  on top of it: does this project need `@preconcurrency import Sentry`, or
//  do the closures type-check as plain `@Sendable` values against a bare
//  `import Sentry`?
//
//  Answer, verified by `xcodebuild build` against this target: a bare
//  `import Sentry` is sufficient. sentry-cocoa's ObjC headers already
//  annotate `SentryOptions.beforeSend` / `.beforeBreadcrumb` as
//  `NS_SWIFT_SENDABLE` (the same fact wxyc-ios-64/WXYC/iOS/WXYCApp.swift
//  notes for `tracesSampler`), so a Swift closure literal assigned directly
//  to either property is accepted under complete concurrency checking with
//  no additional annotation. No `@preconcurrency`, no `@Sendable` spelled
//  out by hand, no `nonisolated(unsafe)` anywhere in this file.
//
//  Created by Jake Bromberg on 08/19/26.
//  Copyright © 2026 WXYC. All rights reserved.
//

import Sentry

/// Starts the Sentry SDK. Full options (privacy contract, DSN, sample rates)
/// land in a follow-up commit on this same file; the spike's job is only to
/// prove the closure shapes compile.
enum TelemetryBootstrap {
    static func start() {
        SentrySDK.start { options in
            options.dsn = "https://spike@example.invalid/0"

            options.beforeSend = { event in
                event
            }

            options.beforeBreadcrumb = { breadcrumb in
                breadcrumb
            }
        }
    }
}
