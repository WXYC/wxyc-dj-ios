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

    fileprivate static func urlBearingError() -> NSError {
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

    @Test("sanitized drops the underlying-error chain and replaces the debug description with the domain")
    func sanitizedStripsTheDiagnosticChain() {
        let result = PostHogErrorReporter.sanitized(Self.urlBearingError())

        #expect(result.domain == NSURLErrorDomain)
        #expect(result.code == NSURLErrorNotConnectedToInternet)
        #expect(result.userInfo[NSUnderlyingErrorKey] == nil)
        #expect(result.userInfo[NSDebugDescriptionErrorKey] as? String == NSURLErrorDomain)
    }

    /// The allowlist, not a denylist (issue #233 review): a free-text
    /// `NSLocalizedDescriptionKey`, a `CustomNSError`'s keys, or a curated
    /// error's `caseName` are all gone, since posthog-ios builds
    /// `exception.value` from `localizedDescription` once the debug
    /// description is absent. What is left is domain, code, and a debug
    /// description that *is* the domain.
    @Test(
        "sanitized keeps domain and code only, with the domain as the debug description",
        arguments: [
            NSError(
                domain: "org.wxyc.dj.test",
                code: 7,
                userInfo: [
                    NSLocalizedDescriptionKey: "Could not reach https://api.wxyc.org/x?y=1 for dj.kendra87@wxyc-test.example",
                    NSLocalizedFailureReasonErrorKey: "dj.kendra87@wxyc-test.example",
                    "customKey": "free text"
                ]
            ),
            TelemetryErrorClassification.curated(AuthError.rejected(message: "server copy")) as NSError,
            PostHogErrorReporterTests.urlBearingError()
        ]
    )
    func sanitizedKeepsOnlyDomainAndCode(_ error: NSError) {
        let result = PostHogErrorReporter.sanitized(error)

        #expect(result.domain == error.domain)
        #expect(result.code == error.code)
        #expect(Set(result.userInfo.keys) == [NSDebugDescriptionErrorKey])
        #expect(result.userInfo[NSDebugDescriptionErrorKey] as? String == error.domain)
        #expect(!result.localizedDescription.contains("kendra87"))
        #expect(!"\(result.userInfo)".contains("server copy"))
    }

    @Test("the userInfo allowlist ships empty")
    func userInfoAllowlistIsEmpty() {
        #expect(PostHogErrorReporter.allowedUserInfoKeys.isEmpty)
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

    @Test("dropped_since_last is an integer property only when positive, and clears the $exception allowlist")
    func droppedSinceLastProperty() {
        #expect(PostHogErrorReporter.properties(context: "ctx", extra: [:])[AnalyticsPrivacyAllowlist.droppedSinceLastKey] == nil)
        let properties = PostHogErrorReporter.properties(context: "ctx", extra: [:], droppedSinceLast: 4)
        #expect(properties["dropped_since_last"] as? Int == 4)
        #expect(AnalyticsPrivacyAllowlist.errorReportKeys == ["error_context", "error_extra", "dropped_since_last"])
        let onException = AnalyticsPrivacyAllowlist.filterNonSDKProperties(properties, event: AnalyticsPrivacyAllowlist.exceptionEventName)
        let elsewhere = AnalyticsPrivacyAllowlist.filterNonSDKProperties(properties, event: "other")
        #expect(onException["dropped_since_last"] as? Int == 4)
        #expect(elsewhere["dropped_since_last"] == nil)
    }

    @Test("properties omit the extra key when there is no extra detail")
    func propertiesOmitEmptyExtra() {
        let properties = PostHogErrorReporter.properties(context: "ctx", extra: [:])

        #expect(properties[AnalyticsPrivacyAllowlist.errorExtraKey] == nil)
    }

    @Test("the error-report keys clear the allowlist on $exception and stay disjoint from the event catalog's keys")
    func errorReportKeysClearTheFilter() {
        let filtered = AnalyticsPrivacyAllowlist.filterNonSDKProperties([
            AnalyticsPrivacyAllowlist.errorContextKey: "ctx",
            AnalyticsPrivacyAllowlist.errorExtraKey: ["storeError.code": 1],
            "not_on_any_allowlist": 1
        ], event: AnalyticsPrivacyAllowlist.exceptionEventName)

        #expect(filtered[AnalyticsPrivacyAllowlist.errorContextKey] as? String == "ctx")
        #expect(filtered[AnalyticsPrivacyAllowlist.errorExtraKey] != nil)
        #expect(filtered["not_on_any_allowlist"] == nil)
        #expect(AnalyticsPrivacyAllowlist.errorReportKeys.isDisjoint(with: AnalyticsPrivacyAllowlist.allowedKeys))
    }

    @Test("every extra key a production call site sends is on the reviewed extra-key list")
    func productionExtraKeysAreAllowlisted() {
        let properties = PostHogErrorReporter.properties(
            context: "AppDependencies.init",
            extra: ["storeError": .errorIdentity(domain: "NSCocoaErrorDomain", code: 4)]
        )
        let extra = properties[AnalyticsPrivacyAllowlist.errorExtraKey] as? [String: Any] ?? [:]

        #expect(Set(extra.keys).isSubset(of: AnalyticsPrivacyAllowlist.errorExtraKeys))
        #expect(!extra.isEmpty)
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

/// Issue #233 review: the dual run is only real while the production
/// composition root actually lists both members. Fails if a later slice of
/// the Sentry removal (Backend-Service#3393) drops ``PostHogErrorReporter``
/// from the composite.
@Suite("Production error-reporter wiring")
struct ProductionErrorReporterWiringTests {
    @Test("the production composite reports to PostHog and to Sentry")
    func productionCompositeIncludesPostHog() {
        let members = AppDependencies.makeProductionErrorReporter().reporters

        #expect(members.contains { $0 is PostHogErrorReporter })
        #expect(members.contains { $0 is SentryErrorReporter })
    }
}
