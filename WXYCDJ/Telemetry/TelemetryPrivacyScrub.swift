//
//  TelemetryPrivacyScrub.swift
//  WXYCDJ
//
//  The pure, SDK-free half of issue #106's privacy contract: walking an
//  arbitrary telemetry payload (an NSError's userInfo, a breadcrumb's data,
//  a free-form description string) and stripping every URL query/fragment it
//  carries. Deliberately no `import Sentry` -- `TelemetryBootstrap`'s
//  `beforeSend`/`beforeBreadcrumb` closures are thin adapters over this type,
//  so keeping the actual walk here (rather than inline in those closures)
//  lets WXYCDJTests assert on it directly via `@testable import WXYCDJ`,
//  with no Sentry type in the call signature -- see ErrorReporting.swift's
//  header for why that boundary matters to the test target.
//
//  Created by Jake Bromberg on 08/19/26.
//  Copyright © 2026 WXYC. All rights reserved.
//

import Foundation
import WXYCAPI

/// Scrubs URL query strings and fragments out of telemetry payloads, at
/// every shape they show up in: a structured `userInfo`-style dictionary, a
/// bare `URL`/`String` value, or a query string embedded as a *substring* of
/// a larger free-form description.
enum TelemetryPrivacyScrub {
    // MARK: - Structured payloads

    /// Scrubs a single leaf value from a telemetry payload -- an
    /// `NSError.userInfo` entry, a breadcrumb's `data` value, and so on.
    /// Recurses into nested dictionaries/arrays **and nested `NSError`s** so
    /// a caller never has to know the payload's exact shape up front; every
    /// other type (numbers, bools, dates, ...) passes through unchanged,
    /// since only text, URLs, and error objects that might carry either can
    /// hold a query string.
    ///
    /// The `NSError` case (issue #106 review Fix 5) exists because
    /// `NSUnderlyingErrorKey` is a routine `URLError.userInfo` key URLSession
    /// populates on a nested transport failure, and its value is itself an
    /// `NSError` -- a leaf the walk didn't previously descend into, then
    /// rendered downstream by Sentry's serializer via the nested error's own
    /// `description`, which (exactly like the top-level curated/`URLError`
    /// case `scrubEmbeddedURLs` exists for) inlines its *entire* `userInfo`
    /// dictionary as free text. Rebuilding the error with a
    /// recursively-scrubbed `userInfo` closes that at every nesting depth,
    /// not just one level down -- an underlying error can itself carry
    /// another `NSUnderlyingErrorKey`.
    static func scrub(_ value: Any) -> Any {
        switch value {
        case let url as URL:
            return URLScrubbing.scrub(url)
        case let nsURL as NSURL:
            return URLScrubbing.scrub(nsURL as URL) as NSURL
        case let nsError as NSError:
            return scrub(nsError)
        case let string as String:
            return scrubEmbeddedURLs(in: string)
        case let dictionary as [String: Any]:
            return scrub(dictionary)
        case let array as [Any]:
            return array.map(scrub)
        default:
            return value
        }
    }

    /// `scrub(_:Any)` specialized to a nested `NSError` -- rebuilds it with
    /// the same domain and code, but with `userInfo` recursively scrubbed
    /// through `scrub(_:[String:Any])`. See `scrub(_:Any)`'s doc comment for
    /// why this leaf matters: it is the one Foundation-supplied shape the
    /// walk didn't cover before, and it is exactly what `NSUnderlyingErrorKey`
    /// carries.
    static func scrub(_ error: NSError) -> NSError {
        NSError(domain: error.domain, code: error.code, userInfo: scrub(error.userInfo))
    }

    /// `scrub(_:Any)` specialized to a whole dictionary -- the shape every
    /// call site in `TelemetryBootstrap` actually has in hand
    /// (`breadcrumb.data`, `event.context["user info"]`,
    /// `exception.mechanism.data`).
    static func scrub(_ dictionary: [String: Any]) -> [String: Any] {
        var scrubbed: [String: Any] = [:]
        scrubbed.reserveCapacity(dictionary.count)
        for (key, value) in dictionary {
            scrubbed[key] = scrub(value)
        }
        return scrubbed
    }

    // MARK: - Free-form text

    /// Scrubs every URL *substring* found in free-form text, not just a
    /// value that is itself a whole URL end-to-end.
    ///
    /// `WXYCAPI.URLScrubbing.scrub(_:String)` is deliberately conservative:
    /// it only touches a value that parses as a URL in its entirety, leaving
    /// ordinary prose untouched -- the right call for a value that's
    /// *supposed* to be exactly one URL, which is every leaf `scrub(_:Any)`
    /// above hands it. It is the wrong tool for `exception.mechanism.desc` /
    /// `exception.value`: sentry-cocoa builds both from `NSError.description`
    /// (`SentryClient.exceptionForError:`), and Foundation's default
    /// `NSError.description` renders the *entire* `userInfo` dictionary
    /// inline as text --
    /// `UserInfo={NSErrorFailingURLStringKey=https://.../library/search?
    /// artist=..., ...}` -- so a query-carrying URL only ever shows up there
    /// as a substring, never as the whole field. This scans with
    /// `NSDataDetector` (the same detector iOS uses to recognize tappable
    /// links) and replaces each match's query/fragment with nothing, leaving
    /// every character outside a detected URL untouched.
    ///
    /// A strict generalization of the whole-string case, not a second code
    /// path: if `text` happens to *be* exactly one URL, the detector matches
    /// the entire string and this produces the same result
    /// `URLScrubbing.scrub(_:String)` would.
    static func scrubEmbeddedURLs(in text: String) -> String {
        guard let detector = Self.linkDetector else { return text }
        let matches = detector.matches(in: text, range: NSRange(text.startIndex..<text.endIndex, in: text))
        guard !matches.isEmpty else { return text }

        var result = text
        // Back-to-front: each replacement shrinks `result`, but only from
        // that match's position onward, so ranges for the matches still to
        // come (all to the left, since NSDataDetector returns matches in
        // left-to-right order) stay valid against the mutated string.
        for match in matches.reversed() {
            guard let url = match.url else { continue }
            let scrubbedURL = URLScrubbing.scrub(url)
            guard scrubbedURL != url, let range = Range(match.range, in: result) else { continue }
            result.replaceSubrange(range, with: scrubbedURL.absoluteString)
        }
        return result
    }

    /// Built once: `NSDataDetector` construction parses a grammar internally
    /// and the type is documented as safe to reuse across many calls.
    private static let linkDetector = try? NSDataDetector(
        types: NSTextCheckingResult.CheckingType.link.rawValue
    )
}
