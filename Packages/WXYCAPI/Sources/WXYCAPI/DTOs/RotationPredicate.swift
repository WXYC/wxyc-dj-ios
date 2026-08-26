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

/// A rotation record's expiry, as the client can actually know it: **three**
/// states, not two.
///
/// The third state is the whole reason this type exists rather than a plain
/// `CalendarDate?`. Absent and unreadable are *opposite* answers — absent means
/// **no expiry** (in rotation indefinitely) while unreadable must fail **closed**
/// (treated as expired) — so collapsing an unparseable wire value into `nil`
/// would leave a record whose expiry we cannot read in rotation forever, which
/// is precisely the silently-wrong shelf ``RotationPredicate`` exists to
/// prevent.
///
/// That distinction is not theoretical: it is pinned by the `CatalogRow` ↔
/// ``AlbumInfo/Rotation`` parity matrix (issue #95), which asserts both row
/// types answer identically for `("H", "not-a-date")`, `("H", "")` and
/// `("H", "2026-6-2")`. Typing the field as `CalendarDate?` and decoding
/// strictly — the obvious reading of issue #79 — would instead make `CatalogRow`
/// *throw* on those, and a throw inside `APIClient.decodeNDJSON` fails the whole
/// catalog fetch rather than one row. This type gets #79's real payoff (the
/// comparison is over `CalendarDate`, so the padded-lexicographic-compare
/// precondition is gone) without trading away per-field decode tolerance the
/// clone depends on.
public enum RotationKillDate: Sendable, Hashable {
    /// The key was absent or null — the record has **no** expiry.
    case noExpiry
    /// A readable calendar day.
    case expires(CalendarDate)
    /// Present but unparseable. Retained verbatim so it round-trips back onto
    /// the wire (and into the SQLite clone blob) exactly as the server sent it,
    /// rather than being normalized away by a client that couldn't read it.
    case unreadable(String)

    /// Builds the state from a raw wire value, applying the same prefix-tolerant
    /// parse both row types need. `nil` (absent/null) is ``noExpiry``; anything
    /// that parses is ``expires``; anything else is ``unreadable``.
    public init(wireValue raw: String?) {
        guard let raw else { self = .noExpiry; return }
        guard let day = RotationPredicate.calendarDay(from: raw) else {
            self = .unreadable(raw)
            return
        }
        self = .expires(day)
    }

    /// The readable day, if there is one. `nil` for **both** ``noExpiry`` and
    /// ``unreadable`` — so never branch rotation state on this; call
    /// ``RotationPredicate/isInRotation(bin:killDate:today:)``, which
    /// distinguishes them.
    public var day: CalendarDate? {
        if case .expires(let day) = self { return day }
        return nil
    }

    /// The value as it belongs on the wire: the `YYYY-MM-DD` rendering of a
    /// readable day, the original text of an unreadable one, `nil` for no
    /// expiry.
    public var wireValue: String? {
        switch self {
        case .noExpiry: return nil
        case .expires(let day): return day.description
        case .unreadable(let raw): return raw
        }
    }
}

/// Encodes as the **bare wire value** — a `"YYYY-MM-DD"` string, or null — not
/// as an enum envelope. That is not cosmetic: ``SQLiteCatalogStore`` persists
/// each ``CatalogRow`` as a `JSONCoders`-encoded blob, so this encoding *is* the
/// on-disk format for the clone. Emitting the bare value is what keeps a clone
/// written by any build readable by any other — an enum envelope would make the
/// two formats mutually unreadable — and an ``unreadable(_:)`` value round-trips
/// verbatim rather than being normalized away by a client that couldn't parse
/// it.
///
/// It is **not** byte-identical to what the server sent, in two reachable cases,
/// and neither is a defect worth closing — but both are worth knowing before
/// treating a re-encoded blob as a copy of the response:
///
/// - An ``expires(_:)`` re-encodes through `CalendarDate.description`, so a
///   value that reached ``init(wireValue:)`` as a *timestamp* is persisted as
///   its leading day (`"2026-07-01T20:00:00-04:00"` → `"2026-07-01"`). That is
///   the prefix tolerance in ``RotationPredicate/calendarDay(from:)`` showing
///   through, and the discarded time-of-day is precisely what the compare must
///   never consult, so normalizing on the way to disk loses nothing this type
///   is allowed to use.
/// - ``noExpiry`` encodes an explicit `null`, where the previous `String?`
///   property's synthesized `encodeIfPresent` omitted the key. Both decode back
///   to ``noExpiry`` via `decodeIfPresent`, so old and new clone blobs stay
///   mutually readable — which is the property that actually matters.
extension RotationKillDate: Codable {
    public init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .noExpiry
            return
        }
        // Narrowing, never throwing: the same tolerance CatalogRow's decoder
        // applies at the key level, so a dirty value can't take out the row.
        self.init(wireValue: try container.decode(String.self))
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        if let wireValue {
            try container.encode(wireValue)
        } else {
            try container.encodeNil()
        }
    }
}

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
///
/// ## Why the comparison is typed on `CalendarDate` (issue #79)
///
/// This rule used to compare zero-padded `"YYYY-MM-DD"` **strings**, because a
/// `Foundation.Date` is an instant and reconstructing the wire day from one
/// means choosing a time zone — any choice being wrong for some input. That
/// made lexicographic ordering equivalent to chronological ordering *only* for
/// the fixed-width form, an unenforceable precondition the two entry points
/// carried in doc comments and enforced by staying `internal`.
///
/// ``CalendarDate`` removes the precondition rather than restating it: it
/// stores `(year, month, day)` and nothing else, and its `Comparable` is a
/// total order over that triple which never consults `Calendar`/`TimeZone` —
/// the exact property the padded string was standing in for, now held by the
/// type instead of by a comment. The `internal` visibility on the pure cores
/// below is therefore no longer load-bearing for correctness; it is kept only
/// so callers reach the rule through their own type's public
/// `isInRotation(asOf:timeZone:)`.
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
    /// This is the **only** rotation rule, and both row types now reach it with
    /// the same ``RotationKillDate`` — ``CatalogRow`` because it decodes to one,
    /// ``AlbumInfo/Rotation`` because it converts its raw string at the call.
    /// There is deliberately no second overload: an overload is a second place
    /// the two paths could drift, which is the exact failure this file exists to
    /// make unrepresentable.
    ///
    /// ``RotationKillDate/unreadable(_:)`` is treated as **expired**, not as "no
    /// expiry" — see that type for why the two must not collapse.
    static func isInRotation(bin: String?, killDate: RotationKillDate, today: CalendarDate) -> Bool {
        guard bin != nil else { return false }
        switch killDate {
        case .noExpiry: return true
        case .unreadable: return false
        case .expires(let day): return day > today
        }
    }

    /// The leading calendar day of an ISO-8601 date or date-time, or `nil` when
    /// the value isn't one.
    ///
    /// Taking the prefix rather than demanding an exact-width match is what
    /// keeps a full timestamp (`"2026-06-23T20:00:00-04:00"`) comparable against
    /// a bare day without either reinterpreting it through a time zone or
    /// failing closed on a legitimately-in-rotation record. The server has never
    /// sent that shape for either rotation column, and `/library/info`'s block is
    /// a hedge against a projection that doesn't exist yet — so the wire shape is
    /// the thing not to assume.
    ///
    /// This is deliberately **more lenient than `CalendarDate`'s own decoder**,
    /// which requires exactly ten bytes and would reject that timestamp
    /// outright, so know how far the leniency now reaches. There are three
    /// callers, and it is no longer confined to the hedge: ``RotationKillDate``'s
    /// `init(wireValue:)` (so it covers ``CatalogRow``'s catalog-export decode —
    /// and, through that type's `Codable`, the value persisted to the clone,
    /// which is normalized to its leading day),
    /// ``AlbumInfo/Rotation/isInRotation(today:)``, and
    /// ``WXYCDateFormatting/dateOnly(fromISOString:locale:)``. All three want the
    /// same answer to the same question — "what calendar day is this?" — which is
    /// why they share one parse rather than each picking a strictness.
    static func calendarDay(from raw: String) -> CalendarDate? {
        guard raw.count >= 10 else { return nil }
        let day = Array(raw.prefix(10))
        for (offset, character) in day.enumerated() {
            if offset == 4 || offset == 7 {
                guard character == "-" else { return nil }
            } else {
                // ASCII `0`-`9` specifically: `Character.isNumber` also accepts
                // other Unicode digit forms, which would pass the shape check
                // and then fail (or worse, succeed oddly) on the parse below.
                guard ("0"..."9").contains(character) else { return nil }
            }
        }
        guard let year = Int(String(day[0..<4])),
              let month = Int(String(day[5..<7])),
              let dayOfMonth = Int(String(day[8..<10]))
        else { return nil }
        // CalendarDate's throwing init owns real-calendar-day validation
        // (correct days-in-month, leap years), so "2026-02-30" is rejected here
        // exactly as it would be on the wire rather than being compared as a
        // plausible-looking triple. Going through the public init rather than
        // constructing a JSON string to feed the decoder keeps this a parse, not
        // a round-trip.
        return try? CalendarDate(year: year, month: month, day: dayOfMonth)
    }
}
