//
//  PostHogErrorReporterTests.swift
//  WXYCDJTests
//
//  The pure halves of PostHogErrorReporter (issue #233) and the composite
//  that fans a report out to Sentry and PostHog. Nothing here touches the
//  PostHog SDK: the end-to-end `$exception` belt is in
//  PostHogPrivacyPipelineTests.
//
//  Created by Jake Bromberg on 10/19/26.
//  Copyright © 2026 WXYC. All rights reserved.
//

import Foundation
import Testing
import WXYCAPI
@testable import WXYCDJ

@Suite("PostHogErrorReporter")
struct PostHogErrorReporterTests {
    private static let leakyDescription = "failed for dj.kendra87@wxyc-test.example"

    private static func urlBearingError() -> NSError {
        let underlying = NSError(
            domain: NSURLErrorDomain,
            code: NSURLErrorTimedOut,
            userInfo: [
                NSDebugDescriptionErrorKey: leakyDescription,
                NSURLErrorFailingURLStringErrorKey: "https://api.wxyc.org/library?artist=Juana%20Molina"
            ]
        )
        return NSError(
            domain: NSURLErrorDomain,
            code: NSURLErrorNotConnectedToInternet,
            userInfo: [
                NSDebugDescriptionErrorKey: leakyDescription,
                NSUnderlyingErrorKey: underlying
            ]
        )
    }

    @Test("sanitized drops the underlying-error chain and the debug description, keeping domain and code")
    func sanitizedStripsTheDiagnosticChain() {
        let result = PostHogErrorReporter.sanitized(Self.urlBearingError())

        #expect(result.domain == NSURLErrorDomain)
        #expect(result.code == NSURLErrorNotConnectedToInternet)
        #expect(result.userInfo[NSUnderlyingErrorKey] == nil)
        #expect(result.userInfo[NSDebugDescriptionErrorKey] == nil)
    }

    @Test("sanitized keeps the curated userInfo an AuthError or APIError carries")
    func sanitizedKeepsCuratedUserInfo() throws {
        let curated = TelemetryErrorClassification.curated(AuthError.rejected(message: "server copy")) as NSError

        let result = PostHogErrorReporter.sanitized(curated)

        #expect(result.domain == curated.domain)
        #expect(result.code == curated.code)
        #expect(result.userInfo["caseName"] as? String == curated.userInfo["caseName"] as? String)
        #expect(!"\(result.userInfo)".contains("server copy"))
    }

    @Test("properties carry the context and nest extras under one key, flattening an error identity")
    func propertiesShape() throws {
        let properties = PostHogErrorReporter.properties(
            context: "AppDependencies.init",
            extra: [
                "count": .int(3),
                "flag": .bool(true),
                "kind": .string("catalog"),
                "storeError": .errorIdentity(domain: "NSCocoaErrorDomain", code: 4)
            ]
        )

        #expect(properties[AnalyticsPrivacyAllowlist.errorContextKey] as? String == "AppDependencies.init")
        let extra = try #require(properties[AnalyticsPrivacyAllowlist.errorExtraKey] as? [String: Any])
        #expect(extra["count"] as? Int == 3)
        #expect(extra["flag"] as? Bool == true)
        #expect(extra["kind"] as? String == "catalog")
        #expect(extra["storeError.domain"] as? String == "NSCocoaErrorDomain")
        #expect(extra["storeError.code"] as? Int == 4)
    }

    @Test("properties omit the extra key when there is no extra detail")
    func propertiesOmitEmptyExtra() {
        let properties = PostHogErrorReporter.properties(context: "ctx", extra: [:])

        #expect(properties[AnalyticsPrivacyAllowlist.errorExtraKey] == nil)
    }

    @Test("the error-report keys clear the allowlist and stay disjoint from the event catalog's keys")
    func errorReportKeysClearTheFilter() {
        let filtered = AnalyticsPrivacyAllowlist.filterNonSDKProperties([
            AnalyticsPrivacyAllowlist.errorContextKey: "ctx",
            AnalyticsPrivacyAllowlist.errorExtraKey: ["k": 1],
            "not_on_any_allowlist": 1
        ])

        #expect(filtered[AnalyticsPrivacyAllowlist.errorContextKey] as? String == "ctx")
        #expect(filtered[AnalyticsPrivacyAllowlist.errorExtraKey] != nil)
        #expect(filtered["not_on_any_allowlist"] == nil)
        #expect(AnalyticsPrivacyAllowlist.errorReportKeys.isDisjoint(with: AnalyticsPrivacyAllowlist.allowedKeys))
    }
}

@Suite("CompositeErrorReporter")
struct CompositeErrorReporterTests {
    private struct Boom: Error {}

    @Test("every member receives the original error, context and extra, in order")
    func fansOutToEveryMember() {
        let first = SpyErrorReporter()
        let second = SpyErrorReporter()
        let composite = CompositeErrorReporter([first, second])

        composite.report(Boom(), context: "ctx", extra: ["n": .int(1)])

        for spy in [first, second] {
            #expect(spy.reportCount == 1)
            #expect(spy.reports.first?.error is Boom)
            #expect(spy.reports.first?.context == "ctx")
            #expect(spy.reports.first?.extra == ["n": .int(1)])
        }
    }
}
