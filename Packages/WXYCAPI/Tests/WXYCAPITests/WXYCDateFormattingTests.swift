//
//  WXYCDateFormattingTests.swift
//  WXYCAPITests
//
//  Pins the date-only render helpers so a raw "YYYY-MM-DD" wire string (the
//  catalog export's rotation_kill_date) renders identically to a decoded Date
//  (the /library/info rotation block) — same GMT-anchored abbreviated form, no
//  host-time-zone drift, raw passthrough when the string isn't a calendar date.
//
//  Created by Jake on 06/27/26.
//  Copyright © 2026 WXYC. All rights reserved.
//

import Foundation
import Testing
@testable import WXYCAPI

@Suite("WXYCDateFormatting date-only string rendering")
struct WXYCDateFormattingTests {
    @Test("a YYYY-MM-DD string renders to the same abbreviated GMT form as a decoded Date")
    func stringMatchesDecodedDate() throws {
        // The catalog export carries kill dates as raw "YYYY-MM-DD"; /library/info
        // carries them as a Date decoded at midnight GMT. Both must render the same.
        let raw = "2026-07-15"
        let decoded = try #require(
            try? Date(raw, strategy: Date.ISO8601FormatStyle(timeZone: .gmt)
                .year().month().day().dateSeparator(.dash))
        )
        let posix = Locale(identifier: "en_US_POSIX")
        let fromString = WXYCDateFormatting.dateOnly(fromISOString: raw, locale: posix)
        let fromDate = decoded.formatted(
            WXYCDateFormatting.dateOnlyFormatStyle.locale(posix))
        #expect(fromString == fromDate)
        #expect(fromString == "Jul 15, 2026")
    }

    @Test("the day survives the render regardless of locale-independent parsing")
    func daySurvives() {
        // Regression guard mirroring rotationDateRendersInGMTRegardlessOfHostTimeZone:
        // a date-only string parsed + rendered through the GMT-anchored path must not
        // slip a day. (No host-time-zone dependence in the helper.)
        let rendered = WXYCDateFormatting.dateOnly(
            fromISOString: "2026-01-01", locale: Locale(identifier: "en_US_POSIX"))
        #expect(rendered == "Jan 1, 2026")
    }

    @Test("a non-calendar-date string passes through verbatim")
    func unparseablePassesThrough() {
        // Data-safety: a dirty value must never blank the field or crash — show it raw.
        #expect(WXYCDateFormatting.dateOnly(fromISOString: "not a date") == "not a date")
        #expect(WXYCDateFormatting.dateOnly(fromISOString: "") == "")
    }
}
