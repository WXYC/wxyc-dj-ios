//
//  JSONCoders.swift
//  WXYCAPI
//
//  JSONEncoder/JSONDecoder configured for the Backend-Service wire format:
//  snake_case keys (via per-DTO CodingKeys) and ISO-8601 timestamps with
//  optional fractional seconds.
//
//  Created by Jake on 5/14/26.
//  Copyright © 2026 WXYC. All rights reserved.
//

import Foundation
// Targeted import -- see RotationPredicate.swift / issue #129 for why this names
// the single type rather than importing the module wholesale.
import struct WXYCAPIModels.CalendarDate

enum JSONCoders {
    static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        // Backend-Service emits ISO-8601 both with and without fractional
        // seconds, so try the more specific parser first and fall through.
        //
        // There is deliberately NO date-only (`YYYY-MM-DD`) branch here, and
        // adding one back would reintroduce the defect issue #79 removed. A
        // `Date` is an instant, so parsing a bare calendar day into one has to
        // invent a time-of-day and a UTC anchor the value never had — and every
        // subsequent render through `Calendar.current` then slips to the
        // previous day on any host west of UTC. This strategy applies to EVERY
        // `Date` field the decoder meets, so the old fallback did that silently
        // to any date-only field added later, whether or not anyone had thought
        // about it.
        //
        // Nothing is losing tolerance here: the branch was already dead. The
        // only two fields decoding to `Date` through this strategy are
        // `AlbumInfo.addDate` and `AlbumSearchResult.addDate`, both sourced from
        // `library.add_date`, which is a `timestamp with time zone` column
        // (Backend-Service `shared/database/src/schema.ts`) and `format:
        // date-time` in api.yaml. The genuinely date-only columns —
        // `rotation.add_date` / `rotation.kill_date`, Postgres `date` reaching
        // the wire via `::text` — are not decoded as `Date` anywhere: the export
        // path types them as `CalendarDate` (``CatalogRow/rotationKillDate``)
        // and the `/library/info` path holds them raw (``AlbumInfo/Rotation``).
        //
        // A date-only field that needs a type should use `CalendarDate`, which
        // decodes through its own `singleValueContainer` and never touches this
        // strategy at all.
        d.dateDecodingStrategy = .custom { decoder in
            let container = try decoder.singleValueContainer()
            let raw = try container.decode(String.self)
            if let date = try? Date(raw, strategy: Date.ISO8601FormatStyle(includingFractionalSeconds: true)) {
                return date
            }
            if let date = try? Date(raw, strategy: Date.ISO8601FormatStyle()) {
                return date
            }
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "Unrecognized date format: \(raw)"
            )
        }
        return d
    }()

    static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        return e
    }()
}

/// Render-side counterpart to `JSONCoders` for **calendar days** — a date with
/// no time and no zone, as rotation `add_date` / `kill_date` carry.
///
/// The GMT pinning below is no longer papering over a decode that fabricated an
/// instant (issue #79 removed that). It is now purely an internal rendering
/// anchor: `Date.FormatStyle` can only format a `Date`, so a calendar day has to
/// be materialised as one somewhere. Constructing it in GMT and formatting it in
/// GMT round-trips exactly, and both halves live in this one type, so the two
/// can't drift apart the way a construct-here/format-there split could.
public enum WXYCDateFormatting {
    /// Abbreviated date, no time, anchored to GMT. Matches the
    /// `Date.formatted(date: .abbreviated, time: .omitted)` shape rotation rows
    /// have always rendered with, minus the time-zone drift.
    public static let dateOnlyFormatStyle: Date.FormatStyle = {
        var style = Date.FormatStyle(date: .abbreviated, time: .omitted)
        style.timeZone = .gmt
        return style
    }()

    private static let gmtCalendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .gmt
        return calendar
    }()

    /// Renders a ``CalendarDate`` — the typed path, used wherever a date-only
    /// wire value has been narrowed at decode (today
    /// ``CatalogRow/rotationKillDate``).
    ///
    /// `locale` is injectable so tests can pin the en_US_POSIX rendering; it
    /// defaults to the device locale.
    public static func dateOnly(_ day: CalendarDate, locale: Locale = .current) -> String {
        let components = DateComponents(year: day.year, month: day.month, day: day.day)
        // GMT in, GMT out (see the type doc). A CalendarDate is validated at
        // construction, so these components always name a real day and the only
        // way `date(from:)` returns nil is a Foundation-level failure; falling
        // back to the type's own `YYYY-MM-DD` description keeps this total
        // rather than blanking the field.
        guard let date = gmtCalendar.date(from: components) else { return day.description }
        return date.formatted(dateOnlyFormatStyle.locale(locale))
    }

    /// Renders a raw `YYYY-MM-DD` wire string — the **un-narrowed** path, used
    /// only where a date-only value is deliberately still held as the string the
    /// server sent (today ``AlbumInfo/Rotation``, whose shape api.yaml no longer
    /// declares at all).
    ///
    /// Delegates to ``dateOnly(_:locale:)`` after parsing, so the two paths
    /// cannot render the same day differently. Parsing goes through
    /// ``RotationPredicate/calendarDay(from:)``, which is prefix-tolerant, so a
    /// full timestamp renders as its leading day rather than falling through to
    /// the raw form.
    ///
    /// A value that doesn't parse as a calendar date passes through
    /// **verbatim** — data-safety: never blank the field, never crash on a dirty
    /// value, the same fail-soft posture as the row-survival decoding in
    /// ``CatalogRow``.
    public static func dateOnly(fromISOString raw: String, locale: Locale = .current) -> String {
        guard let day = RotationPredicate.calendarDay(from: raw) else { return raw }
        return dateOnly(day, locale: locale)
    }
}
