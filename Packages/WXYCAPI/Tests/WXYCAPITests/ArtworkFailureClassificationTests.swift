//
//  ArtworkFailureClassificationTests.swift
//  WXYCAPITests
//
//  Pins ArtworkFailureClassification.indictsURL (issue #86): a connectivity-class
//  URLError leaves the URL in the running, while a resource-level URLError or any
//  non-URLError retires it.
//
//  Created by Jake on 08/16/26.
//  Copyright © 2026 WXYC. All rights reserved.
//

import Foundation
import Testing
@testable import WXYCAPI

@Suite("Artwork failure classification")
struct ArtworkFailureClassificationTests {
    // Retiring a URL is a one-way door for the caller (AlbumDetailView's set is
    // permanent for the view's life), so a connectivity blip must never retire a
    // healthy cover: doing so would hand the header to LML's label logo the moment
    // the network came back, reintroducing the #83 defect on a path with no
    // self-recovery.

    @Test(
        "a connectivity-class failure does not retire the URL",
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
    func transientFailuresAreNotRecorded(code: URLError.Code) {
        #expect(ArtworkFailureClassification.indictsURL(URLError(code)) == false)
    }

    @Test(
        "a resource-level URLError retires the URL",
        arguments: [
            // What a CDN's 403/404 error page looks like by the time it reaches the
            // image decoder — the expired-signature and purged-asset cases #86
            // exists to recover from. Classifying every URLError as transient would
            // disable the fallthrough.
            URLError.Code.cannotDecodeContentData,
            .badServerResponse,
            .fileDoesNotExist,
            .resourceUnavailable,
            .badURL,
            .unsupportedURL,
        ]
    )
    func resourceLevelFailuresAreRecorded(code: URLError.Code) {
        #expect(ArtworkFailureClassification.indictsURL(URLError(code)))
    }

    @Test("a non-URLError failure retires the URL")
    func nonURLErrorFailuresAreRecorded() {
        // `AsyncImage` surfaces a decode failure that isn't a `URLError` for a body
        // that transferred fine but isn't an image; that indicts the URL, so it must
        // fall through rather than fail safe.
        #expect(ArtworkFailureClassification.indictsURL(CocoaError(.fileReadCorruptFile)))
    }
}
