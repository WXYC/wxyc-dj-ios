//
//  TrackMatchBadge.swift
//  WXYCDJ
//
//  Inline annotation rendered on a search row when the row was surfaced by
//  a track-title match (catalog-track-search Track 1 CTA or Track 2 LML).
//  Tells the DJ *why* the row came back — "matched on a track on this
//  release" — so the result is trustworthy when artist/album alone wouldn't
//  have explained it.
//
//  Created by Jake on 5/20/26.
//  Copyright © 2026 WXYC. All rights reserved.
//

import SwiftUI
import WXYCAPI

struct TrackMatchBadge: View {
    let hints: [TrackMatchHint]

    var body: some View {
        if let summary = Self.summary(from: hints) {
            Label(summary, systemImage: "music.note.list")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
    }

    /// "via track: «Title»" for one hint, "via track: «Title» (+N more)"
    /// when there are multiple. Returns nil for an empty array so the view
    /// renders nothing.
    static func summary(from hints: [TrackMatchHint]) -> String? {
        guard let first = hints.first else { return nil }
        if hints.count == 1 {
            return "via track: \(first.title)"
        }
        return "via track: \(first.title) (+\(hints.count - 1) more)"
    }
}
