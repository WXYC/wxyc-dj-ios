//
//  DateOnlyDecodeRetirementTests.swift
//  WXYCAPITests
//
//  Pins that JSONCoders no longer parses a bare calendar day into a
//  GMT-midnight Date (issue #79). The render side lives in
//  WXYCDateFormattingTests -- one home each, so neither drifts to a weaker bar
//  while the other looks green.
//
//  Created by Jake on 08/25/26.
//  Copyright © 2026 WXYC. All rights reserved.
//

import Foundation
import Testing
@testable import WXYCAPI
import struct WXYCAPIModels.CalendarDate

@Suite("Date-only decode retirement")
struct DateOnlyDecodeRetirementTests {
    private struct Holder: Decodable {
        let when: Date
    }

    @Test func bareCalendarDayNoLongerDecodesAsADate() {
        // The retired fallback turned "2026-06-22" into 2026-06-22T00:00:00Z --
        // an instant the value never had, which then rendered as the 21st on
        // every host west of UTC. It applied to EVERY Date field the decoder met,
        // so any date-only field added later inherited the defect silently.
        // Rejecting it is what makes that impossible rather than merely unused.
        #expect(throws: DecodingError.self) {
            try JSONCoders.decoder.decode(Holder.self, from: Data(#"{"when":"2026-06-22"}"#.utf8))
        }
    }

    @Test(arguments: [
        "2026-06-22T18:30:00Z",
        "2026-06-22T18:30:00.123Z",
        "2026-06-22T14:30:00-04:00",
    ])
    func timestampsStillDecode(raw: String) throws {
        // The two live callers -- AlbumInfo.addDate and AlbumSearchResult.addDate
        // -- both source `library.add_date`, a `timestamp with time zone` column
        // and `format: date-time` in api.yaml. Retiring the date-only branch must
        // not touch them.
        let holder = try JSONCoders.decoder.decode(
            Holder.self,
            from: Data(#"{"when":"\#(raw)"}"#.utf8)
        )
        #expect(holder.when.timeIntervalSince1970 > 0)
    }
}
