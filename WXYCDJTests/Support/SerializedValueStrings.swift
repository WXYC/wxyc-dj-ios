//
//  SerializedValueStrings.swift
//  WXYCDJTests
//
//  The full recursive string-leaf walk both telemetry privacy-pipeline belt
//  tests need (issue #117). SentryPrivacyPipelineTests originated this
//  inline as a private `allStrings(in:)`, scoped to Sentry's serialized
//  event tree; PostHogPrivacyPipelineTests needs the identical traversal
//  over a PostHog event's merged `properties` dict, and previously asserted
//  against four named keys instead -- which left the entire `$`-prefixed
//  surface (the one `filterNonSDKProperties` passes through untouched by
//  design, and exactly where the `$rageclick` leak lived) unobserved by any
//  test. Promoted here rather than duplicated a second time: the whole
//  point of a full-tree walk is that it holds one bar -- "nowhere in the
//  captured output" -- and a second, independently-maintained copy could
//  drift to holding a weaker one without either suite noticing.
//
//  Created by Jake Bromberg on 08/24/26.
//  Copyright © 2026 WXYC. All rights reserved.
//

import Foundation

/// Recursively collects every `String` in a decoded JSON-like tree --
/// nested `[String: Any]` dictionaries and `[Any]` arrays, as produced by
/// Sentry's `Event.serialize()` or a PostHog event's fully merged
/// `properties` dict. Anything else (`Int`, `Bool`, `NSNull`, ...) is
/// skipped. Deliberately not path-specific: a privacy belt test's job is to
/// prove a secret is nowhere in the output, and enumerating every string
/// the pipeline actually produced is the only way to hold that bar, rather
/// than the handful of fields a test happened to anticipate.
///
/// **Dictionary keys are collected as well as values, and that is not
/// symmetry for its own sake -- it closes a real channel.** The type-level
/// guards ADR 0007 describes constrain property *values*: `TelemetryValue`
/// has no free-text case, `AnalyticsPropertyValue` has no `.string` case.
/// Neither constrains a **key**. `ErrorReporter.report(_:context:extra:)`
/// takes `extra` as `[String: TelemetryValue]`, so `extra: [typedSearchText:
/// .int(1)]` type-checks, and `TelemetryPrivacyScrub.scrub(_:[String: Any])`
/// copies keys through verbatim (`scrubbed[key] = scrub(value)`) -- it
/// scrubs values only. A values-only walk therefore could not see a DJ
/// identifier that rode in as a key, which is exactly the "a field nobody
/// thought to assert on" failure mode this whole helper exists to rule out.
enum SerializedValueStrings {
    static func allStrings(in value: Any) -> [String] {
        switch value {
        case let string as String:
            return [string]
        case let dictionary as [String: Any]:
            return dictionary.flatMap { [$0.key] + allStrings(in: $0.value) }
        case let array as [Any]:
            return array.flatMap(allStrings)
        default:
            return []
        }
    }
}
