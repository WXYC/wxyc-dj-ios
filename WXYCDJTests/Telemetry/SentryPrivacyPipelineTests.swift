//
//  SentryPrivacyPipelineTests.swift
//  WXYCDJTests
//
//  The end-to-end assertion issue #106 requires: capture a real error
//  through the real, started SDK -- privacy options, beforeBreadcrumb,
//  beforeSend, the whole TelemetryBootstrap.start(dsn:) pipeline -- and
//  inspect what actually reached the serialized event. The unit-level
//  TelemetryPrivacyScrubTests and ErrorReportingTests already pin the pure
//  logic in isolation; this file is the belt to that suspenders; it is the
//  only place these two guarantees are checked *through the SDK itself*
//  rather than against the helper functions alone.
//
//  Reaches Sentry-touching behavior exclusively through
//  TelemetryBootstrap.debugCaptureSerializedEvent(for:dsn:breadcrumb:via:),
//  the `#if DEBUG`-only test hook -- this file itself has no `import
//  Sentry` and cannot: WXYCDJTests is never linked against the Sentry
//  package (see project.yml's Sentry package comment), so the hook's plain
//  `[String: Any]` return is the only way to inspect a captured event here.
//
//  Created by Jake Bromberg on 08/19/26.
//  Copyright © 2026 WXYC. All rights reserved.
//

import Foundation
import Testing
import WXYCAPI
@testable import WXYCDJ

@Suite("Sentry privacy pipeline (end-to-end)")
struct SentryPrivacyPipelineTests {
    /// Never the placeholder production DSN, and never a real one --
    /// syntactically valid so `SentrySDK.start` accepts it, pointed at a
    /// project that doesn't exist so nothing this test does can reach a real
    /// Sentry ingest endpoint.
    private static let testDSN = "https://test@o0.ingest.sentry.io/0"

    private static let secretQueryMarker = "SECRET_QUERY_MARKER"
    private static let secretServerCopy = "SECRET_SERVER_REJECTION_COPY"

    /// Walks the entire serialized event tree and collects every `String`
    /// leaf -- deliberately not path-specific (`event["exception"]
    /// ["values"][0]["value"]`, etc.): the acceptance bar is "nowhere in the
    /// serialized event", and asserting against every string this pipeline
    /// produced is the only way to actually hold that bar, rather than the
    /// handful of fields this test happened to anticipate.
    private static func allStrings(in value: Any) -> [String] {
        switch value {
        case let string as String:
            return [string]
        case let dictionary as [String: Any]:
            return dictionary.values.flatMap(allStrings)
        case let array as [Any]:
            return array.flatMap(allStrings)
        default:
            return []
        }
    }

    @Test func capturedURLErrorLeavesNoQueryStringAnywhereInTheEvent() throws {
        let queryURL = "https://api.wxyc.org/library/search?artist=\(Self.secretQueryMarker)"
        let error = URLError(.cannotDecodeContentData, userInfo: [
            // Both keys: a real URLSession failure populates both the
            // (deprecated but still-emitted) String form and the URL form,
            // and TelemetryPrivacyScrub.scrub(_:Any) has a distinct code
            // path for each -- this exercises both.
            NSURLErrorFailingURLStringErrorKey: queryURL,
            NSURLErrorFailingURLErrorKey: URL(string: queryURL)!,
            NSLocalizedDescriptionKey: "cannot decode raw data",
        ])

        let event = try #require(TelemetryBootstrap.debugCaptureSerializedEvent(
            for: error,
            dsn: Self.testDSN,
            breadcrumb: { crumb in
                crumb.type = "http"
                crumb.message = "GET \(queryURL)"
                crumb.data = ["url": queryURL, "method": "GET"]
            }
        ))

        let strings = Self.allStrings(in: event)
        #expect(!strings.isEmpty)
        for string in strings {
            #expect(!string.contains(Self.secretQueryMarker), "leaked query text in: \(string)")
            #expect(!string.contains("?"), "leaked a query string in: \(string)")
        }
    }

    @Test func capturedMessageBearingAuthErrorLeavesNoServerCopyAnywhereInTheEvent() throws {
        let error = AuthError.rejected(message: Self.secretServerCopy)

        let event = try #require(TelemetryBootstrap.debugCaptureSerializedEvent(
            for: error,
            dsn: Self.testDSN
        ))

        let strings = Self.allStrings(in: event)
        #expect(!strings.isEmpty)
        for string in strings {
            #expect(!string.contains(Self.secretServerCopy), "leaked server copy in: \(string)")
        }
    }

    @Test func capturedServerFailureLeavesNoServerCopyAnywhereInTheEvent() throws {
        // The status int itself is exactly the fact this privacy contract is
        // willing to keep -- see ErrorReportingTests' curatesAuthErrorServerFailureWithStatusButNoMessage
        // for that positive assertion at the NSError level. This test only
        // needs to confirm the negative: the message never rides along.
        let error = AuthError.serverFailure(status: 503, message: Self.secretServerCopy)

        let event = try #require(TelemetryBootstrap.debugCaptureSerializedEvent(
            for: error,
            dsn: Self.testDSN
        ))

        let strings = Self.allStrings(in: event)
        for string in strings {
            #expect(!string.contains(Self.secretServerCopy), "leaked server copy in: \(string)")
        }
    }
}
