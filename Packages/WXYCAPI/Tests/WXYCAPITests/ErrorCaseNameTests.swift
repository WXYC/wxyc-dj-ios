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
    ] as [(APIError, String, Int?)])
    func apiErrorCaseNameMapsEveryCaseToItsExpectedNameAndStatus(
        error: APIError,
        expectedName: String,
        expectedStatusCode: Int?
    ) {
        #expect(error.caseName.name == expectedName)
        #expect(error.caseName.statusCode == expectedStatusCode)
    }

    /// `.decoding(detail:)` is the deliberate carve-out elsewhere (its detail
    /// is narrowed, not reported raw), but `caseName` itself must still drop
    /// it -- the mapping is the one Sentry actually reports through, never
    /// the raw enum.
    @Test func apiErrorCaseNameNeverCarriesTheAssociatedMessage() {
        let cases: [APIError] = [
            .http(status: 500, message: "SECRET_PAYLOAD"),
            .decoding(detail: "SECRET_PAYLOAD"),
            .network("SECRET_PAYLOAD"),
        ]
        for error in cases {
            #expect(!error.caseName.name.contains("SECRET_PAYLOAD"))
            #expect(String(describing: error.caseName.statusCode).contains("SECRET_PAYLOAD") == false)
        }
    }
}
