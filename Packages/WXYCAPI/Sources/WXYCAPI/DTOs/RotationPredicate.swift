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
    ///
    /// A `killDay` the compare cannot read is treated as **expired**, not as "no
    /// expiry". Both row types hold this value as the raw wire string, so a
    /// malformed one reaches here intact rather than being rejected at decode —
    /// and a bare `killDay > today` on garbage is worse than useless: `"not-a-date"`
    /// sorts above every real `"YYYY-MM-DD"`, so a corrupt value would read as in
    /// rotation *forever*, which is precisely the silently-wrong shelf this rule
    /// is supposed to prevent. Failing closed costs at most a badge on a record
    /// whose expiry is unreadable; failing open leaves dead records on the shelf
    /// indefinitely with nothing to surface it.
    static func isInRotation(bin: String?, killDay: String?, today: String) -> Bool {
        guard bin != nil else { return false }
        guard let killDay else { return true }
        guard let day = calendarDay(from: killDay) else { return false }
        return day > today
    }

    /// The leading `"YYYY-MM-DD"` of an ISO-8601 date or date-time, or `nil` when
    /// the value isn't one.
    ///
    /// Taking the prefix rather than demanding an exact-width match is what keeps
    /// a full timestamp (`"2026-06-23T20:00:00-04:00"`) comparable against a bare
    /// day without either reinterpreting it through a time zone or failing closed
    /// on a legitimately-in-rotation record — the server has never sent that shape
    /// for this column, but this type is a hedge against a projection that doesn't
    /// exist yet, so the wire shape is the thing not to assume. Digits are checked
    /// against ASCII `0`-`9` specifically: `Character.isNumber` also accepts other
    /// Unicode digit forms, which would pass the shape check and then sort
    /// arbitrarily against an ASCII day.
    static func calendarDay(from raw: String) -> String? {
        guard raw.count >= 10 else { return nil }
        let day = Array(raw.prefix(10))
        for (offset, character) in day.enumerated() {
            if offset == 4 || offset == 7 {
                guard character == "-" else { return nil }
            } else {
                guard ("0"..."9").contains(character) else { return nil }
            }
        }
        return String(day)
    }

    /// The calendar day of `now` in `timeZone` as a zero-padded `"YYYY-MM-DD"`
    /// string, via the locale-independent ISO-8601 calendar so the result never
    /// drifts with host locale/calendar settings. Uses a value-type format style
    /// (no per-call `DateFormatter` allocation) — the same date-only shape
    /// ``JSONCoders`` uses for the inverse parse — so it stays cheap if called
    /// per row. Batch callers compute the day once and reuse it across rows.
    ///
    /// This converts *the client's clock* to a day, and nothing else. Both row
    /// types hold their kill date as the raw wire string and hand it to
    /// ``isInRotation(bin:killDay:today:)`` untouched, so no caller passes a
    /// rotation date through here — there is no `Date` on that side to convert.
    /// Do not reintroduce one: turning the wire value into a `Date` and
    /// rendering it back means choosing a zone, and any choice is wrong for some
    /// input (GMT suits a bare `"2026-06-23"` but shifts an offset-bearing
    /// timestamp to the following day), which would make the online path
    /// disagree with the cloned one about the same album.
    static func localDay(_ now: Date = Date(), timeZone: TimeZone = .current) -> String {
        now.formatted(
            Date.ISO8601FormatStyle(timeZone: timeZone)
                .year().month().day()
                .dateSeparator(.dash)
        )
    }
}
