//
//  CalendarDate.swift
//  WXYCAPI
//
//  Re-exports the generated calendar-day type under this package's own name, so
//  no consumer has to name WXYCAPIModels to spell a date-only value.
//
//  Created by Jake on 08/26/26.
//  Copyright © 2026 WXYC. All rights reserved.
//

// Targeted import, matching TrackMatchHint.swift / SignInResponse.swift rather
// than a blanket `import WXYCAPIModels`. Since the 1.47.0 contract advance that
// module declares five names WXYCAPI also declares (EmailSignInRequest,
// LookupEmailRequest/Response, SendLoginCodeRequest, OTPSignInRequest), and a
// same-module declaration shadows an imported one *silently* -- see issue #129.
// Naming the single type keeps those out of scope entirely.
//
// This is the ONE place that names WXYCAPIModels for this type. It used to be
// repeated in eleven files -- four package sources, six package tests, and one
// app test -- which made the mitigation above eleven things to remember rather
// than one, and put that last one on the wrong side of the app-layer rule.
import struct WXYCAPIModels.CalendarDate

/// A date-only value: `(year, month, day)` and nothing else.
///
/// Generated from api.yaml's `format: date` mapping (`typeMappings:
/// date=CalendarDate`), and aliased here for the same reason
/// ``TrackMatchHint`` is: **app-layer code must never import `WXYCAPIModels`**
/// (see the repo's `CLAUDE.md`), and until this alias existed, naming a
/// `CalendarDate` outside the package forced exactly that import — which
/// ``CatalogRow``'s public initializer made unavoidable for anyone constructing
/// a row, `WXYCDJTests` included.
///
/// Why the type is date-only rather than a `Foundation.Date`: a `Date` is a
/// point on the UTC timeline, so decoding a bare `YYYY-MM-DD` into one
/// fabricates a time-of-day and a UTC anchor the value never had, shifting the
/// rendered day back by one on every host west of UTC. Comparison is a total
/// order over the three components and never consults `Calendar`/`TimeZone`,
/// which is the property ``RotationPredicate``'s expiry compare needs and the
/// one a zero-padded `"YYYY-MM-DD"` string used to stand in for (issue #79).
public typealias CalendarDate = WXYCAPIModels.CalendarDate

extension CalendarDate {
    /// The leading calendar day of an ISO-8601 date or date-time, or `nil` when
    /// the value isn't one.
    ///
    /// Deliberately **more lenient than `CalendarDate`'s own `Decodable`**,
    /// which demands exactly ten bytes and would reject a full timestamp
    /// outright. Taking the prefix is what keeps
    /// `"2026-06-23T20:00:00-04:00"` comparable against a bare day without
    /// either reinterpreting it through a time zone or failing closed on a
    /// legitimately-in-rotation record. The server has never sent that shape for
    /// either rotation column, and `/library/info`'s rotation block is a hedge
    /// against a projection that doesn't exist yet — so the wire shape is
    /// precisely the thing not to assume.
    ///
    /// It lives here, beside the strict decoder it relaxes, rather than on
    /// ``RotationPredicate``: nothing about it is rotation-specific, and hanging
    /// a general `String -> CalendarDate?` parse off the rotation rule left a
    /// package-root render helper (``WXYCDateFormatting/dateOnly(fromISOString:locale:)``)
    /// reaching into a `DTOs/` domain namespace to parse a date.
    ///
    /// Scans UTF-8 bytes and accumulates digits directly — no `[Character]`
    /// array, no intermediate `String`s, no `Int(String)`. That is not
    /// premature: this runs once per row carrying a kill date on the full
    /// `GET /library/catalog` NDJSON decode **and** again on
    /// `SQLiteCatalogStore.ensureSearchIndex()`'s whole-clone re-decode, so the
    /// per-call allocation the previous form paid was multiplied by ~17k.
    ///
    /// Real-calendar validation (days-in-month, leap years) stays delegated to
    /// the throwing `init(year:month:day:)`, so `"2026-02-30"` is rejected here
    /// exactly as it would be on the wire rather than compared as a
    /// plausible-looking triple.
    public init?(leadingDayOf raw: String) {
        var year = 0, month = 0, dayOfMonth = 0, offset = 0
        for byte in raw.utf8 {
            if offset == 10 { break }
            if offset == 4 || offset == 7 {
                guard byte == UInt8(ascii: "-") else { return nil }
            } else {
                // ASCII digits specifically. `Character.isNumber` would also
                // accept other Unicode digit forms, which pass a shape check and
                // then parse oddly or not at all.
                guard byte >= UInt8(ascii: "0"), byte <= UInt8(ascii: "9") else { return nil }
                let digit = Int(byte - UInt8(ascii: "0"))
                if offset < 4 { year = year * 10 + digit }
                else if offset < 7 { month = month * 10 + digit }
                else { dayOfMonth = dayOfMonth * 10 + digit }
            }
            offset += 1
        }
        // Short values fall out here rather than needing a length pre-check: a
        // `raw.count` on the way in would walk the WHOLE string for graphemes
        // when only the first ten bytes can matter.
        guard offset == 10 else { return nil }
        guard let parsed = try? CalendarDate(year: year, month: month, day: dayOfMonth) else { return nil }
        self = parsed
    }
}
