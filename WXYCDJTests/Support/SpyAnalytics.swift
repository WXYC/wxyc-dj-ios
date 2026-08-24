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

    /// Every `capture` call, in order.
    var captures: [Capture] { state.withLock { $0 } }

    /// Convenience for the common "was anything captured at all" assertion.
    var captureCount: Int { captures.count }

    /// Names of every captured event, in order -- the common assertion shape
    /// ("did `search_performed` fire, and only once").
    var capturedNames: [String] { captures.map(\.name) }

    func capture(_ event: some AnalyticsEvent) {
        let record = Capture(name: type(of: event).name, properties: event.properties)
        state.withLock { $0.append(record) }
    }
}
