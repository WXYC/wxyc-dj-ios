//
//  ErrorReportingTests.swift
//  WXYCDJTests
//
//  Pins the pure, SDK-free half of issue #106's privacy contract:
//  TelemetryErrorClassification.curated(_:) never lets a message-bearing
//  AuthError/APIError case reach a form that could carry its associated
//  string, a URLError passes through untouched (its domain/code bridge is
//  the point), and TelemetryValue's own Equatable conformance and the
//  ErrorReporter default extension behave as documented.
//
//  Created by Jake Bromberg on 08/19/26.
//  Copyright © 2026 WXYC. All rights reserved.
//

import Foundation
import Testing
import WXYCAPI
@testable import WXYCDJ

@Suite("TelemetryErrorClassification")
struct TelemetryErrorClassificationTests {
    private struct SecretPayload {
        static let authRejection = "SECRET_SERVER_REJECTION_COPY"
        static let apiHTTPMessage = "SECRET_HTTP_BODY_TEXT"
    }

    // MARK: - AuthError

    @Test func curatesAuthErrorRejectedWithNoServerCopyInAnyForm() {
        let error = AuthError.rejected(message: SecretPayload.authRejection)

        let curated = TelemetryErrorClassification.curated(error) as NSError

        #expect(curated.domain == TelemetryErrorClassification.Domain.authError)
        #expect(curated.userInfo["caseName"] as? String == "rejected")
        #expect(curated.userInfo["statusCode"] == nil)
        // The full NSError description (what `mechanism.desc` is built from)
        // must not carry the message either -- not just the userInfo dict.
        #expect(!"\(curated)".contains(SecretPayload.authRejection))
        #expect(!String(describing: curated).contains(SecretPayload.authRejection))
    }

    @Test func curatesAuthErrorServerFailureWithStatusButNoMessage() {
        let error = AuthError.serverFailure(status: 503, message: "database is down")

        let curated = TelemetryErrorClassification.curated(error) as NSError

        #expect(curated.domain == TelemetryErrorClassification.Domain.authError)
        #expect(curated.userInfo["caseName"] as? String == "serverFailure")
        #expect(curated.userInfo["statusCode"] as? Int == 503)
        #expect(!"\(curated)".contains("database is down"))
    }

    /// Every `AuthError` case name reachable through `caseName`, curated,
    /// carries only the two allowlisted keys -- a compile obligation
    /// upstream (`AuthError.caseName` is a total switch), turned into a
    /// runtime guarantee here that this classification never widens the
    /// allowlist per case.
    @Test(arguments: [
        AuthError.invalidCredentials,
        .network(message: "boom"),
        .offline(message: "offline"),
        .missingSessionToken,
        .serverFailure(status: 500, message: "boom"),
        .rejected(message: nil),
        .rateLimited,
        .notSignedIn,
    ])
    func curatedAuthErrorUserInfoIsAllowlistedToCaseNameAndStatus(error: AuthError) {
        let curated = TelemetryErrorClassification.curated(error) as NSError

        #expect(Set(curated.userInfo.keys).isSubset(of: ["caseName", "statusCode"]))
        #expect(curated.userInfo["caseName"] as? String == error.caseName.name)
    }

    // MARK: - APIError

    @Test func curatesAPIErrorHTTPWithStatusButNoMessage() {
        let error = APIError.http(status: 404, message: SecretPayload.apiHTTPMessage)

        let curated = TelemetryErrorClassification.curated(error) as NSError

        #expect(curated.domain == TelemetryErrorClassification.Domain.apiError)
        #expect(curated.userInfo["caseName"] as? String == "http")
        #expect(curated.userInfo["statusCode"] as? Int == 404)
        #expect(!"\(curated)".contains(SecretPayload.apiHTTPMessage))
    }

    @Test func curatesAPIErrorDecodingWithNoDetailCarried() {
        // APIError.caseName already drops .decoding(detail:)'s string (see
        // APIClient.swift) -- this pins that curated(_:) inherits that
        // stripping rather than reaching past caseName to the raw case.
        let error = APIError.decoding(detail: "type mismatch at artist_name")

        let curated = TelemetryErrorClassification.curated(error) as NSError

        #expect(curated.userInfo["caseName"] as? String == "decoding")
        #expect(!"\(curated)".contains("artist_name"))
    }

    // MARK: - Passthrough

    @Test func urlErrorPassesThroughUnchanged() {
        let error = URLError(.cannotDecodeContentData)

        let curated = TelemetryErrorClassification.curated(error) as NSError

        #expect(curated.domain == NSURLErrorDomain)
        #expect(curated.code == URLError.Code.cannotDecodeContentData.rawValue)
    }

    private struct UnrelatedError: Error {}

    @Test func unrelatedErrorTypesPassThroughUnchanged() {
        let curated = TelemetryErrorClassification.curated(UnrelatedError())

        #expect(curated is UnrelatedError)
    }

    // MARK: - stableCode(for:)

    @Test func stableCodeIsDeterministicAcrossCalls() {
        #expect(TelemetryErrorClassification.stableCode(for: "rejected") == TelemetryErrorClassification.stableCode(for: "rejected"))
    }

    @Test func stableCodeDiffersAcrossDistinctNames() {
        let names = ["invalidCredentials", "network", "offline", "missingSessionToken", "serverFailure", "rejected", "rateLimited", "notSignedIn"]
        let codes = Set(names.map(TelemetryErrorClassification.stableCode(for:)))

        #expect(codes.count == names.count)
    }
}

@Suite("TelemetryValue")
struct TelemetryValueTests {
    @Test func equatableComparesByRenderedTextForString() {
        #expect(TelemetryValue.string("context") == TelemetryValue.string("context"))
        #expect(TelemetryValue.string("a") != TelemetryValue.string("b"))
    }

    @Test func equatableDistinguishesCasesEvenWithMatchingPayload() {
        let asInt: TelemetryValue = .int(1)
        let asBool: TelemetryValue = .bool(true)
        #expect(asInt != asBool)
    }

    @Test func errorIdentityComparesBothFields() {
        #expect(TelemetryValue.errorIdentity(domain: "d", code: 1) == .errorIdentity(domain: "d", code: 1))
        #expect(TelemetryValue.errorIdentity(domain: "d", code: 1) != .errorIdentity(domain: "d", code: 2))
    }
}

@Suite("ErrorReporter default extension")
struct ErrorReporterDefaultExtensionTests {
    @Test func reportWithNoExtraDefaultsToAnEmptyDictionary() {
        let spy = SpyErrorReporter()

        spy.report(URLError(.timedOut), context: "test context")

        #expect(spy.reports.count == 1)
        #expect(spy.reports.first?.context == "test context")
        #expect(spy.reports.first?.extra.isEmpty == true)
    }
}
