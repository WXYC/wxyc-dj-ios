//
//  CalendarDayFixture.swift
//  WXYCAPITests
//
//  Terse `CalendarDate` construction from a `"YYYY-MM-DD"` literal, so rotation
//  fixtures read the way the wire does (issue #79).
//
//  Created by Jake on 08/25/26.
//  Copyright © 2026 WXYC. All rights reserved.
//

import Foundation
import Testing
import struct WXYCAPIModels.CalendarDate

/// Builds a ``CalendarDate`` from a `"YYYY-MM-DD"` literal for test fixtures.
///
/// Deliberately **decodes** rather than calling `CalendarDate(year:month:day:)`
/// with hand-split components: decoding is the path production takes, so a
/// fixture written here can't accidentally express a value the wire form
/// couldn't carry. It also keeps the call site as short as the string it
/// replaces, which is what makes a table of rotation cases stay readable.
///
/// Traps on a malformed literal — these are fixtures, not inputs, so a typo
/// should fail the test that wrote it rather than silently yield `nil` and let
/// an assertion pass against the wrong value.
func day(
    _ literal: String,
    sourceLocation: SourceLocation = #_sourceLocation
) -> CalendarDate {
    guard let decoded = try? JSONDecoder().decode(
        CalendarDate.self,
        from: Data("\"\(literal)\"".utf8)
    ) else {
        Issue.record("Not a valid YYYY-MM-DD calendar day: \(literal)", sourceLocation: sourceLocation)
        // Unreachable in a passing suite; keeps the helper non-optional so call
        // sites don't each unwrap a value that is a constant in the source.
        return try! CalendarDate(year: 1970, month: 1, day: 1)
    }
    return decoded
}
