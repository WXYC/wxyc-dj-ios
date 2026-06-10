//
//  TrackMatchBadgeTests.swift
//  WXYCDJTests
//
//  Pins the user-visible string the search row's track-match annotation
//  renders. The view itself is a thin SwiftUI wrapper around
//  `TrackMatchBadge.summary(from:)` — exercise the formatter, not the view
//  tree, since the rendering is one Label.
//
//  Created by Jake on 5/20/26.
//  Copyright © 2026 WXYC. All rights reserved.
//

import Foundation
import Testing
@testable import WXYCAPI
@testable import WXYCDJ

@Suite("TrackMatchBadge")
struct TrackMatchBadgeTests {
    @Test func emptyHintsRenderNothing() {
        #expect(TrackMatchBadge.summary(from: []) == nil)
    }

    @Test func singleHintRendersViaTrackPrefix() throws {
        let hint = try TrackMatchHint.fixture(
            title: "In a Sentimental Mood",
            source: "cta"
        )
        #expect(TrackMatchBadge.summary(from: [hint]) == "via track: In a Sentimental Mood")
    }

    @Test func multipleHintsAppendOverflowCount() throws {
        let hints = [
            try TrackMatchHint.fixture(title: "VI Scose Poise", source: "discogs_master"),
            try TrackMatchHint.fixture(title: "Eutow", source: "discogs_master"),
            try TrackMatchHint.fixture(title: "Pen Expers", source: "discogs_master"),
        ]
        #expect(TrackMatchBadge.summary(from: hints) == "via track: VI Scose Poise (+2 more)")
    }
}

// Lightweight constructor for tests. Mirrors the JSON-decoded shape but
// surfaces decode failures as a thrown error rather than a process trap,
// so a bad fixture string fails the test cleanly instead of crashing the
// runner.
private extension TrackMatchHint {
    static func fixture(title: String, source rawSource: String) throws -> TrackMatchHint {
        let payload = """
            { "title": "\(title)", "source": "\(rawSource)" }
            """
        return try JSONCoders.decoder.decode(TrackMatchHint.self, from: Data(payload.utf8))
    }
}
