//
//  WXYCDateFormattingTests.swift
//  WXYCAPITests
//
//  Pins the date-only render helpers so the two representations a kill date can
//  still take — a narrowed CalendarDate (the catalog export) and a raw wire
//  string (the /library/info rotation block) — render identically, with no
//  host-time-zone drift and raw passthrough when the string isn't a calendar
//  date.
//
//  Created by Jake on 06/27/26.
//  Copyright © 2026 WXYC. All rights reserved.
//

import Foundation
import Testing
@testable import WXYCAPI
import struct WXYCAPIModels.CalendarDate

@Suite("WXYCDateFormatting date-only rendering")
struct WXYCDateFormattingTests {
    private let posix = Locale(identifier: "en_US_POSIX")

    @Test("a CalendarDate and the raw string it came from render identically")
    func typedAndRawPathsAgree() {
        // This suite used to assert the raw string matched a Date the test
        // itself built at midnight GMT — the representation `JSONCoders` used to
        // produce for `/library/info` rotation dates. Issue #79 retired that
        // decode, so asserting against it would have kept passing while pinning
        // a shape the app no longer has anywhere: a silently-true test.
        //
        // The parity that still matters is between the two representations that
        // really exist. `CatalogRow` narrows its kill date at decode; the
        // `/library/info` block deliberately keeps the wire string. A DJ can see
        // either for the same album on the same screen, so they must agree.
        let raw = "2026-07-15"
        #expect(
            WXYCDateFormatting.dateOnly(fromISOString: raw, locale: posix)
                == WXYCDateFormatting.dateOnly(day(raw), locale: posix)
        )
    }

    @Test("the abbreviated form is the one DJs have always seen")
    func rendersTheAbbreviatedForm() {
        #expect(WXYCDateFormatting.dateOnly(day("2026-07-15"), locale: posix) == "Jul 15, 2026")
        #expect(WXYCDateFormatting.dateOnly(fromISOString: "2026-07-15", locale: posix) == "Jul 15, 2026")
    }

    @Test("the day never slips, whatever the host time zone")
    func dayNeverSlips() {
        // The whole point of the effort: the rendered day is the wire day. A
        // CalendarDate carries no instant, so there is nothing left for a host
        // zone to shift — Jan 1 is the case that used to render as Dec 31 on
        // every negative-UTC host.
        #expect(WXYCDateFormatting.dateOnly(day("2026-01-01"), locale: posix) == "Jan 1, 2026")
        #expect(WXYCDateFormatting.dateOnly(fromISOString: "2026-01-01", locale: posix) == "Jan 1, 2026")
    }

    @Test("a timestamp renders as its leading day rather than leaking ISO text")
    func timestampRendersAsItsLeadingDay() {
        // Prefix tolerance reaches the renderer, so a hypothetical offset-bearing
        // kill date on the still-raw path shows a day instead of raw ISO text.
        #expect(
            WXYCDateFormatting.dateOnly(fromISOString: "2026-07-15T20:00:00-04:00", locale: posix)
                == "Jul 15, 2026"
        )
    }

    @Test("a non-calendar-date string passes through verbatim")
    func unparseablePassesThrough() {
        // Data-safety: a dirty value must never blank the field or crash — show it raw.
        #expect(WXYCDateFormatting.dateOnly(fromISOString: "not a date") == "not a date")
        #expect(WXYCDateFormatting.dateOnly(fromISOString: "") == "")
    }
}
