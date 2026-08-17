//
//  RotationPredicate.swift
//  WXYCAPI
//
//  The one client-side rotation rule, shared by every row type that carries a
//  rotation record, so the online and offline paths cannot answer differently.
//
//  Created by Jake on 08/17/26.
//  Copyright © 2026 WXYC. All rights reserved.
//

import Foundation

/// The single client-side answer to "is this album in rotation?", shared by the
/// two row types that carry a rotation record: ``CatalogRow`` (the raw
/// `GET /library/catalog` export) and ``AlbumInfo/Rotation`` (the nested block
/// on `GET /library/info`).
///
/// It lives in one place because those two are **alternatives, not
/// complements** — a DJ sees the online answer when `/library/info` responds
/// and the cloned answer when it doesn't, for the same album on the same
/// screen — so any divergence between them reads as the app contradicting
/// itself. Duplicating the rule and pinning the copies with a parity test would
/// only catch a divergence *after* someone wrote it; sharing the rule makes it
/// unrepresentable. Relaxing the strict compare to match a server change is now
/// a one-line edit in one file, which is the point. (Same reasoning as
/// ``AlbumSearchResult/headerStandIn(id:artistName:albumTitle:codeLetters:codeArtistNumber:codeNumber:label:genreName:formatName:plays:onStreaming:artworkURL:)``,
/// which collapsed the two `detailFallback` bridges onto one factory.)
enum RotationPredicate {
    /// Mirrors the server's published predicate for the raw export —
    /// `rotation_bin != null && (kill_date == null || kill_date > today)` —
    /// evaluated against the client's own calendar day, because the export
    /// defers daily kill-date expiry to the client.
    ///
    /// **Any** non-nil `bin` counts as in rotation, including one outside the
    /// current `H`/`M`/`L`/`S` cohorts: that forward-compatibility hedge is why
    /// both row types store the bin raw rather than as the closed
    /// ``RotationBin`` enum (issue #93). An empty-string bin is *not* one of
    /// those — both types normalize `""` to `nil` on decode, so it arrives here
    /// as "no assignment". The kill-date compare is **strict**, matching
    /// `kill_date > CURRENT_DATE`: a record expiring *today* is already out.
    ///
    /// `killDay` and `today` MUST both be zero-padded `"YYYY-MM-DD"` days (the
    /// output of ``localDay(_:timeZone:)``). The lexicographic compare is
    /// equivalent to a chronological one only for that fixed-width form, which
    /// is why this stays `internal` and callers reach it through their type's
    /// public `isInRotation(asOf:timeZone:)`.
    static func isInRotation(bin: String?, killDay: String?, today: String) -> Bool {
        guard bin != nil else { return false }
        guard let killDay else { return true }
        return killDay > today
    }

    /// The calendar day of `now` in `timeZone` as a zero-padded `"YYYY-MM-DD"`
    /// string, via the locale-independent ISO-8601 calendar so the result never
    /// drifts with host locale/calendar settings. Uses a value-type format style
    /// (no per-call `DateFormatter` allocation) — the same date-only shape
    /// ``JSONCoders`` uses for the inverse parse — so it stays cheap if called
    /// per row. Batch callers compute the day once and reuse it across rows.
    ///
    /// Also the renderer for a rotation date that arrives already *parsed*:
    /// `/library/info` ships `kill_date` as a date the decoder turns into a
    /// midnight-GMT `Date`, so ``AlbumInfo/Rotation`` passes it back through
    /// here with `timeZone: .gmt` to recover the wire day before comparing.
    static func localDay(_ now: Date = Date(), timeZone: TimeZone = .current) -> String {
        now.formatted(
            Date.ISO8601FormatStyle(timeZone: timeZone)
                .year().month().day()
                .dateSeparator(.dash)
        )
    }
}
