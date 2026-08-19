//
//  URLScrubbing.swift
//  WXYCAPI
//
//  Strips the query and fragment off a URL (or a String that parses as one),
//  keeping scheme + host + path. Pure Foundation, no SDK -- lives here so
//  `swift test` covers it on the host, the same test-tier split
//  `ArtworkFailureClassification` documents: the app layer wires this into
//  Sentry's `beforeBreadcrumb`/`beforeSend` (issue #106), but the judgment of
//  what counts as safe-to-keep is a pure function this package can own and
//  test without linking an SDK.
//
//  Created by Jake Bromberg on 08/19/26.
//  Copyright © 2026 WXYC. All rights reserved.
//

import Foundation

/// Removes the query string and fragment from a URL, which is where a DJ's
/// typed search text travels on the wire: `GET /library/search?artist=<typed
/// text>` becomes a network breadcrumb, and the same query string rides along
/// on `NSErrorFailingURLStringErrorKey` inside a reported `URLError`'s
/// `userInfo`. Neither is safe to collect (issue #106's privacy contract),
/// but the scheme/host/path triple *is* useful for triage -- knowing a
/// request to `/library/search` failed is the diagnostic; knowing what the DJ
/// typed into it is not.
///
/// Two entry points because the app layer has two different things to scrub:
/// a `URLRequest`'s/breadcrumb's `URL` directly, and an arbitrary
/// `NSError.userInfo` value that may or may not be a URL-shaped `String` (the
/// walk `beforeSend` does over `contexts["user info"]` and
/// `exception.mechanism.data`).
public enum URLScrubbing {
    /// Strips `url`'s query and fragment, preserving scheme, host, and path.
    /// A URL with neither is returned unchanged (structurally equivalent,
    /// though not guaranteed to be the identical `URL` value -- components
    /// are always rebuilt).
    public static func scrub(_ url: URL) -> URL {
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            return url
        }
        components.query = nil
        components.fragment = nil
        return components.url ?? url
    }

    /// Scrubs `string` if -- and only if -- it parses as a URL carrying a
    /// query or fragment; otherwise returns it untouched.
    ///
    /// This is the walk-arbitrary-`userInfo`-values entry point, so it must
    /// be conservative in both directions: a real URL loses its query/
    /// fragment, but a value that merely *looks* URL-shaped without a scheme
    /// (a bare word, a file path fragment, server-authored prose) is not
    /// mistaken for one and mangled. `URL(string:)` is lenient enough to
    /// parse almost any non-URL string as a relative-path URL with no scheme
    /// -- requiring `scheme != nil` is what keeps this from firing on
    /// something like an `NSError.userInfo` message string that happens to
    /// contain a slash.
    public static func scrub(_ string: String) -> String {
        guard let url = URL(string: string),
              url.scheme != nil,
              var components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              components.query != nil || components.fragment != nil
        else {
            return string
        }
        components.query = nil
        components.fragment = nil
        return components.string ?? string
    }
}
