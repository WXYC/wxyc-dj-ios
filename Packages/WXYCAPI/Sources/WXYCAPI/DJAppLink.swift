//
//  DJAppLink.swift
//  WXYCAPI
//
//  Parses the `wxycdj://album/<id>` link the listener app (wxyc-ios-64) opens
//  from a playcut's detail screen (issue #186). Pure Foundation, so `swift test`
//  covers it on the host; the app layer only routes what this returns.
//
//  Created by Jake Bromberg on 10/08/26.
//  Copyright © 2026 WXYC. All rights reserved.
//

import Foundation

/// The custom-URL-scheme entry point. Any app can open a custom scheme, so the
/// link is untrusted input: exactly one shape is accepted and it can only
/// *navigate* to an album, never mutate anything (the DJ taps Add to Bin).
public enum DJAppLink {
    /// The scheme this app registers. The listener app spells the same literal
    /// with no shared source between the repos; both test tables pin it.
    public static let scheme = "wxycdj"

    private static let albumHost = "album"

    /// The catalog album id in `wxycdj://album/<id>`, or `nil` for anything
    /// else. Scheme and host compare case-insensitively (both are, per RFC
    /// 3986); the id must be ASCII digits only (`CatalogID.decimal`, shared
    /// with ``CatalogSpotlight/albumID(from:)``), positive, and fit in `Int`.
    /// Nothing may ride along with the id — no further path, query, fragment,
    /// user, or port.
    public static func albumID(from url: URL) -> Int? {
        guard url.scheme?.lowercased() == scheme,
              url.host()?.lowercased() == albumHost,
              url.user() == nil, url.port == nil,
              url.query() == nil, url.fragment() == nil
        else { return nil }
        let path = url.path(percentEncoded: true)
        guard path.hasPrefix("/") else { return nil }
        guard let albumID = CatalogID.decimal(path.dropFirst()), albumID > 0 else { return nil }
        return albumID
    }
}
