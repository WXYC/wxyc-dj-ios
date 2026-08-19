//
//  ConnectivityErrorClassificationTests.swift
//  WXYCAPITests
//
//  Pins ConnectivityErrorClassification.isConnectivityFailure (issue #106):
//  a connectivity-class URLError is recognized as one, a resource-level
//  URLError and a non-URLError are not. ArtworkFailureClassificationTests
//  covers the same list indirectly through indictsURL -- this suite drives
//  the shared helper directly so the list has one test as well as one home.
//
//  Created by Jake Bromberg on 08/19/26.
//  Copyright © 2026 WXYC. All rights reserved.
//

import Foundation
import Testing
@testable import WXYCAPI

@Suite("Connectivity error classification")
struct ConnectivityErrorClassificationTests {
    @Test(
        "a connectivity-class URLError is recognized as one",
        arguments: [
            URLError.Code.notConnectedToInternet,
            .networkConnectionLost,
            .timedOut,
            .cannotConnectToHost,
            .cannotFindHost,
            .dnsLookupFailed,
            .secureConnectionFailed,
            .dataNotAllowed,
            .internationalRoamingOff,
            .callIsActive,
            .cancelled,
        ]
    )
    func connectivityCodesAreRecognized(code: URLError.Code) {
        #expect(ConnectivityErrorClassification.isConnectivityFailure(URLError(code)))
    }

    @Test(
        "a resource-level URLError is not connectivity",
        arguments: [
            URLError.Code.cannotDecodeContentData,
            .badServerResponse,
            .fileDoesNotExist,
            .resourceUnavailable,
            .badURL,
            .unsupportedURL,
        ]
    )
    func resourceLevelCodesAreNotConnectivity(code: URLError.Code) {
        #expect(ConnectivityErrorClassification.isConnectivityFailure(URLError(code)) == false)
    }

    @Test("a non-URLError is not connectivity")
    func nonURLErrorIsNotConnectivity() {
        #expect(ConnectivityErrorClassification.isConnectivityFailure(CocoaError(.fileReadCorruptFile)) == false)
    }
}
