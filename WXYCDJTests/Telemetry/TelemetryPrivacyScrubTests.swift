//
//  TelemetryPrivacyScrubTests.swift
//  WXYCDJTests
//
//  Pins TelemetryPrivacyScrub's pure walk (issue #106) directly -- no Sentry
//  type involved, so these run against the same guarantee the end-to-end
//  SentryPrivacyPipelineTests exercise through the real SDK: a query string
//  never survives, wherever it's found.
//
//  Created by Jake Bromberg on 08/19/26.
//  Copyright © 2026 WXYC. All rights reserved.
//

import Foundation
import Testing
@testable import WXYCDJ

@Suite("TelemetryPrivacyScrub")
struct TelemetryPrivacyScrubTests {
    // MARK: - scrub(_:Any) leaf values

    @Test func scrubStripsQueryFromAURLValue() {
        let url = URL(string: "https://api.wxyc.org/library/search?artist=Juana+Molina")!

        let scrubbed = TelemetryPrivacyScrub.scrub(url) as? URL

        #expect(scrubbed?.absoluteString == "https://api.wxyc.org/library/search")
    }

    @Test func scrubStripsQueryFromAWholeURLString() {
        let scrubbed = TelemetryPrivacyScrub.scrub(
            "https://api.wxyc.org/library/search?artist=Juana+Molina"
        ) as? String

        #expect(scrubbed == "https://api.wxyc.org/library/search")
    }

    @Test func scrubLeavesOrdinaryProseUntouched() {
        let scrubbed = TelemetryPrivacyScrub.scrub("Chuquimamani-Condori is on the flowsheet") as? String

        #expect(scrubbed == "Chuquimamani-Condori is on the flowsheet")
    }

    @Test func scrubLeavesNonStringNonURLValuesUntouched() {
        #expect(TelemetryPrivacyScrub.scrub(42) as? Int == 42)
        #expect(TelemetryPrivacyScrub.scrub(true) as? Bool == true)
    }

    // MARK: - scrub(_:[String: Any]) recursion

    @Test func scrubRecursesThroughNestedDictionariesAndArrays() throws {
        let payload: [String: Any] = [
            "NSErrorFailingURLStringKey": "https://api.wxyc.org/library/search?artist=Jessica+Pratt",
            "nested": [
                "urls": [
                    "https://api.wxyc.org/proxy/metadata/album?title=On+Your+Own+Love+Again",
                    "not a url at all",
                ] as [Any],
            ] as [String: Any],
            "count": 2,
        ]

        let scrubbed = TelemetryPrivacyScrub.scrub(payload)

        #expect(scrubbed["NSErrorFailingURLStringKey"] as? String == "https://api.wxyc.org/library/search")
        let nested = try #require(scrubbed["nested"] as? [String: Any])
        let urls = try #require(nested["urls"] as? [Any])
        #expect(urls[0] as? String == "https://api.wxyc.org/proxy/metadata/album")
        #expect(urls[1] as? String == "not a url at all")
        #expect(scrubbed["count"] as? Int == 2)
    }

    // MARK: - scrubEmbeddedURLs(in:) -- the compound-description case

    /// The exact shape `NSError.description` renders for a `URLError`
    /// carrying `NSErrorFailingURLStringErrorKey` -- what
    /// `exception.mechanism.desc` actually contains at capture time. The
    /// query string is a *substring* of a much larger string, which is why
    /// `scrubEmbeddedURLs` exists instead of relying on the whole-string
    /// scrub above.
    @Test func scrubEmbeddedURLsStripsAQueryStringBuriedInACompoundDescription() {
        let description = #"Error Domain=NSURLErrorDomain Code=-1017 "cannot decode raw data" UserInfo={NSErrorFailingURLStringKey=https://api.wxyc.org/library/search?artist=Duke+Ellington, NSLocalizedDescription=cannot decode raw data}"#

        let scrubbed = TelemetryPrivacyScrub.scrubEmbeddedURLs(in: description)

        #expect(!scrubbed.contains("?"))
        #expect(!scrubbed.contains("Duke+Ellington"))
        #expect(scrubbed.contains("https://api.wxyc.org/library/search"))
        #expect(scrubbed.contains("Error Domain=NSURLErrorDomain Code=-1017"))
        #expect(scrubbed.contains("NSLocalizedDescription=cannot decode raw data"))
    }

    @Test func scrubEmbeddedURLsHandlesMultipleURLsInOneString() {
        let text = "primary=https://api.wxyc.org/a?x=1 fallback=https://api.wxyc.org/b?y=2"

        let scrubbed = TelemetryPrivacyScrub.scrubEmbeddedURLs(in: text)

        #expect(!scrubbed.contains("?"))
        #expect(scrubbed.contains("https://api.wxyc.org/a"))
        #expect(scrubbed.contains("https://api.wxyc.org/b"))
    }

    @Test func scrubEmbeddedURLsLeavesTextWithNoURLUntouched() {
        let text = "That code isn't right."

        #expect(TelemetryPrivacyScrub.scrubEmbeddedURLs(in: text) == text)
    }

    @Test func scrubEmbeddedURLsLeavesAQuerylessURLUntouched() {
        let text = "GET https://api.wxyc.org/library/catalog succeeded"

        #expect(TelemetryPrivacyScrub.scrubEmbeddedURLs(in: text) == text)
    }
}
