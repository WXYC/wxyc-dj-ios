//
//  ErrorCaseNameTests.swift
//  WXYCAPITests
//
//  Pins the total AuthError.caseName / APIError.caseName mappings (issue
//  #106): every case maps to its expected stable name, a message-bearing
//  case's message never survives into the mapped output, and a status-
//  bearing case's status arrives as a plain Int.
//
//  Created by Jake Bromberg on 08/19/26.
//  Copyright © 2026 WXYC. All rights reserved.
//

import Foundation
import Testing
@testable import WXYCAPI

@Suite("Error case names")
struct ErrorCaseNameTests {
    // MARK: - AuthError

    @Test(arguments: [
        (AuthError.invalidCredentials, "invalidCredentials", nil),
        (AuthError.network(message: "SECRET_PAYLOAD"), "network", nil),
        (AuthError.offline(message: "SECRET_PAYLOAD"), "offline", nil),
        (AuthError.missingSessionToken, "missingSessionToken", nil),
        (AuthError.serverFailure(status: 503, message: "SECRET_PAYLOAD"), "serverFailure", 503),
        (AuthError.rejected(message: "SECRET_PAYLOAD"), "rejected", nil),
        (AuthError.rateLimited, "rateLimited", nil),
        (AuthError.notSignedIn, "notSignedIn", nil),
    ] as [(AuthError, String, Int?)])
    func authErrorCaseNameMapsEveryCaseToItsExpectedNameAndStatus(
        error: AuthError,
        expectedName: String,
        expectedStatusCode: Int?
    ) {
        #expect(error.caseName.name == expectedName)
        #expect(error.caseName.statusCode == expectedStatusCode)
    }

    /// The message-bearing cases must never leak their associated string —
    /// this is the whole point of the mapping. Every case above that carries
    /// a message uses the same sentinel, so a single string search over the
    /// whole enum's output proves none of the four leaks it.
    @Test func authErrorCaseNameNeverCarriesTheAssociatedMessage() {
        let cases: [AuthError] = [
            .network(message: "SECRET_PAYLOAD"),
            .offline(message: "SECRET_PAYLOAD"),
            .serverFailure(status: 503, message: "SECRET_PAYLOAD"),
            .rejected(message: "SECRET_PAYLOAD"),
        ]
        for error in cases {
            #expect(!error.caseName.name.contains("SECRET_PAYLOAD"))
            #expect(String(describing: error.caseName.statusCode).contains("SECRET_PAYLOAD") == false)
        }
    }

    // MARK: - APIError

    @Test(arguments: [
        (APIError.unauthorized, "unauthorized", nil),
        (APIError.notSignedIn, "notSignedIn", nil),
        (APIError.http(status: 500, message: "SECRET_PAYLOAD"), "http", 500),
        (APIError.decoding(detail: "SECRET_PAYLOAD"), "decoding", nil),
        (APIError.network("SECRET_PAYLOAD"), "network", nil),
        (APIError.offline(message: "SECRET_PAYLOAD"), "offline", nil),
    ] as [(APIError, String, Int?)])
    func apiErrorCaseNameMapsEveryCaseToItsExpectedNameAndStatus(
        error: APIError,
        expectedName: String,
        expectedStatusCode: Int?
    ) {
        #expect(error.caseName.name == expectedName)
        #expect(error.caseName.statusCode == expectedStatusCode)
    }

    /// `.http`'s server-authored message and `.network`'s/`.offline`'s
    /// client-side description must never survive into `caseName.name` or
    /// `.statusCode` -- the mapping is the one Sentry actually reports
    /// through, never the raw enum. `.decoding(detail:)` is deliberately
    /// excluded from this list: its narrowed `detail` string IS carried
    /// (through `caseName.detail`, not `.name`/`.statusCode`) — see
    /// `apiErrorCaseNameCarriesTheNarrowedDecodingDetailOnlyOnThatCase` below
    /// for the positive assertion of exactly that.
    @Test func apiErrorCaseNameNeverCarriesTheAssociatedMessage() {
        let cases: [APIError] = [
            .http(status: 500, message: "SECRET_PAYLOAD"),
            .network("SECRET_PAYLOAD"),
            .offline(message: "SECRET_PAYLOAD"),
        ]
        for error in cases {
            #expect(!error.caseName.name.contains("SECRET_PAYLOAD"))
            #expect(String(describing: error.caseName.statusCode).contains("SECRET_PAYLOAD") == false)
            #expect(error.caseName.detail == nil)
        }
    }

    /// The positive half of the `.decoding(detail:)` exception (issue #106
    /// review Fix 4): `caseName.detail` carries exactly the string the case
    /// already held, and every other case's `detail` stays `nil`. Safe only
    /// because `APIClient.describe(_:)` -- the one place that ever
    /// constructs a `.decoding(detail:)` from a real decode failure -- is
    /// narrowed to code-derived facts alone; see that function's own
    /// regression tests in `APIClientTests`.
    @Test func apiErrorCaseNameCarriesTheNarrowedDecodingDetailOnlyOnThatCase() {
        let error = APIError.decoding(detail: "type mismatch at artist_name: expected Int")

        #expect(error.caseName.detail == "type mismatch at artist_name: expected Int")
        #expect(APIError.http(status: 500, message: nil).caseName.detail == nil)
        #expect(APIError.network("boom").caseName.detail == nil)
        #expect(APIError.offline(message: "boom").caseName.detail == nil)
    }
}
