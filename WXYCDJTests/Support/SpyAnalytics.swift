//
//  SpyAnalytics.swift
//  WXYCDJTests
//
//  A recording Analytics double (issue #108) for capture-site tests --
//  mirrors SpyErrorReporter exactly: records every `capture(...)` call
//  verbatim (the event name plus its own `properties` dict, not a
//  re-derived proxy), so a test can pattern-match on it directly. Lock-
//  guarded, matching SpyErrorReporter/SpyBinStore: OSAllocatedUnfairLock is
//  unconditionally Sendable regardless of what it guards.
//
//  Created by Jake Bromberg on 08/24/26.
//  Copyright © 2026 WXYC. All rights reserved.
//

import Foundation
import os
@testable import WXYCDJ

final class SpyAnalytics: Analytics {
    /// One recorded `capture(...)` call.
    struct Capture: Equatable {
        let name: String
        let properties: [String: AnalyticsPropertyValue]
    }

    private let state = OSAllocatedUnfairLock(initialState: [Capture]())

    /// Every `capture` call, in order. Deliberately the only accessor: an
    /// earlier draft mirrored `SpyErrorReporter`'s `reportCount` with
    /// `captureCount`/`capturedNames` conveniences that no test used, which
    /// left two competing idioms and no signal about which was preferred.
    /// Assertions read `captures.count` / `.first` / `.isEmpty` directly.
    var captures: [Capture] { state.withLock { $0 } }

    func capture(_ event: some AnalyticsEvent) {
        let record = Capture(name: type(of: event).name, properties: event.properties)
        state.withLock { $0.append(record) }
    }
}
