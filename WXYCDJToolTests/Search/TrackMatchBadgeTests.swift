//
//  TrackMatchBadgeTests.swift
//  WXYCDJToolTests
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
@testable import WXYCDJTool

@Suite("TrackMatchBadge")
struct TrackMatchBadgeTests {
    @Test func emptyHintsRenderNothing() {
        #expect(TrackMatchBadge.summary(from: []) == nil)
    }

    @Test func singleHintRendersViaTrackPrefix() {
        let hint = TrackMatchHint(
            title: "In a Sentimental Mood",
            source: "cta"
        )
        #expect(TrackMatchBadge.summary(from: [hint]) == "via track: In a Sentimental Mood")
    }

    @Test func multipleHintsAppendOverflowCount() {
        let hints = [
            TrackMatchHint(title: "VI Scose Poise", source: "discogs_master"),
            TrackMatchHint(title: "Eutow", source: "discogs_master"),
            TrackMatchHint(title: "Pen Expers", source: "discogs_master"),
        ]
        #expect(TrackMatchBadge.summary(from: hints) == "via track: VI Scose Poise (+2 more)")
    }
}

// Lightweight constructor for tests. Mirrors the JSON-decoded shape but
// skips JSONDecoder so a test fixture can build a hint inline.
private extension TrackMatchHint {
    init(title: String, source rawSource: String) {
        let payload = """
            { "title": "\(title)", "source": "\(rawSource)" }
            """
        self = try! JSONCoders.decoder.decode(TrackMatchHint.self, from: Data(payload.utf8))
    }
}
