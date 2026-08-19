//
//  ConnectivityErrorClassification.swift
//  WXYCAPI
//
//  The package's one list of "connectivity-class" URLError codes -- the
//  link failed, not the request itself, so the failure says nothing about
//  whatever was being fetched. Factored out of `ArtworkFailureClassification`
//  (issue #86) so `AuthService`'s honest offline/network split (issue #106)
//  can classify against the exact same set instead of maintaining a second
//  copy that could silently drift from the first.
//
//  Created by Jake Bromberg on 08/19/26.
//  Copyright © 2026 WXYC. All rights reserved.
//

import Foundation

/// Whether an error indicts the *link* -- no route to the server, DNS,
/// timeout, captive portal, a deliberate cancellation -- rather than
/// whatever the request was trying to reach.
///
/// This is a judgment two unrelated consumers need for two unrelated
/// questions: `ArtworkFailureClassification` (issue #86) asks whether a
/// failed artwork load should permanently retire its URL from a precedence
/// chain, and `AuthService` (issue #106) asks whether a failed sign-in leg is
/// "being offline" -- a supported mode, never worth reporting -- versus a
/// genuine transport defect worth surfacing to crash reporting. Both
/// questions reduce to the same underlying classification, so it lives once
/// here rather than as two `Set<URLError.Code>` literals that could quietly
/// diverge on the next edit to either call site.
public enum ConnectivityErrorClassification {
    /// Connectivity-class `URLError` codes: the *link* failed, so the error
    /// says nothing about the resource or request itself.
    ///
    /// Deliberately excluded -- these are `URLError`s too, but they describe
    /// the **resource** or the **request**, not the link, and a caller
    /// treating them as connectivity would be wrong: `.cannotDecodeContentData`
    /// / `.badServerResponse` (what a CDN's 403/404 error page looks like by
    /// the time it reaches a decoder), `.fileDoesNotExist`,
    /// `.resourceUnavailable`, `.badURL`, `.unsupportedURL`.
    public static let connectivityCodes: Set<URLError.Code> = [
        .notConnectedToInternet,
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

    /// `true` when `error` is a `URLError` whose code names a link failure
    /// rather than a resource/request failure; `false` for every other
    /// error, including a non-`URLError`.
    public static func isConnectivityFailure(_ error: Error) -> Bool {
        guard let urlError = error as? URLError else { return false }
        return connectivityCodes.contains(urlError.code)
    }
}
