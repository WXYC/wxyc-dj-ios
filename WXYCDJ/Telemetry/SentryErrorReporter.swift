//
//  SentryErrorReporter.swift
//  WXYCDJ
//
//  The real ErrorReporter conformer (issue #106) -- the one Sentry-importing
//  piece of this app's error-reporting seam. Kept in its own file, separate
//  from ErrorReporting.swift's protocol/TelemetryValue/classification logic,
//  precisely so that everything *else* in Telemetry/ stays free of the
//  Sentry import this app deliberately never hands to WXYCDJTests (see
//  ErrorReporting.swift's header and project.yml's Sentry package comment).
//
//  Created by Jake Bromberg on 08/19/26.
//  Copyright © 2026 WXYC. All rights reserved.
//

import Sentry

/// Reports errors to Sentry.
///
/// Holds no mutable state of its own -- `SentrySDK` is the SDK's own
/// internally-synchronized singleton -- so this conforms to `Sendable`
/// trivially and needs no actor isolation of its own.
struct SentryErrorReporter: ErrorReporter {
    func report(_ error: any Error, context: StaticString, extra: [String: TelemetryValue]) {
        // NEVER SentrySDK.capture(error: error) with the raw error. See
        // TelemetryErrorClassification's doc comment: for an AuthError or
        // APIError, `error` is a plain Swift enum, and Sentry builds
        // `exception.value`/`mechanism.desc` from `String(describing: error)`
        // on exactly that shape of bridged error -- which would ship a
        // message-bearing case's associated string (a server's rejection
        // copy, e.g.) verbatim into the event's headline text. `curated(_:)`
        // is what stands between every capture and that leak.
        let reported = TelemetryErrorClassification.curated(error)

        SentrySDK.capture(error: reported) { scope in
            // `context` is a StaticString by construction (see
            // ErrorReporter's doc comment), so this can never carry
            // interpolated runtime content -- safe as a low-cardinality tag.
            scope.setTag(value: "\(context)", key: "context")

            for (key, value) in extra {
                switch value {
                case .int(let number):
                    scope.setExtra(value: number, key: key)
                case .bool(let flag):
                    scope.setExtra(value: flag, key: key)
                case .string(let text):
                    scope.setExtra(value: "\(text)", key: key)
                case .errorIdentity(let domain, let code):
                    scope.setExtra(value: domain, key: "\(key).domain")
                    scope.setExtra(value: code, key: "\(key).code")
                }
            }
        }
    }
}
