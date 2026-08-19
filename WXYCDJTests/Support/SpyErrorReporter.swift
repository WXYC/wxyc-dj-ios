//
//  SpyErrorReporter.swift
//  WXYCDJTests
//
//  A recording ErrorReporter double (issue #106) for capture-site tests --
//  the follow-up work that adds report(...) calls to AppDependencies,
//  BinViewModel, AlbumDetailView, and LoginViewModel. Records every call
//  verbatim, including the original error (not a stringified proxy), so a
//  test can pattern-match on it directly -- `if case let .serverFailure =
//  spy.reports.first?.error as? AuthError`, and so on. Lock-guarded,
//  matching SpyBinStore/FakeThumbnailProvider: OSAllocatedUnfairLock is
//  unconditionally Sendable regardless of what it guards, so a recorded
//  `any Error` (not itself required to be Sendable) can live inside it with
//  no strict-concurrency friction.
//
//  Created by Jake Bromberg on 08/19/26.
//  Copyright © 2026 WXYC. All rights reserved.
//

import Foundation
import os
@testable import WXYCDJ

final class SpyErrorReporter: ErrorReporter {
    /// One recorded `report(...)` call.
    struct Report {
        let error: any Error
        /// `context` rendered to a plain `String` at record time -- a
        /// `StaticString` has no `Equatable`/pattern-matching support of its
        /// own, and a test asserting "reported under context X" wants a
        /// comparable value, not the wrapper type.
        let context: String
        let extra: [String: TelemetryValue]
    }

    private let state = OSAllocatedUnfairLock(initialState: [Report]())

    /// Every `report` call, in order.
    var reports: [Report] { state.withLock { $0 } }

    /// Convenience for the common "was anything reported at all" assertion.
    var reportCount: Int { reports.count }

    func report(_ error: any Error, context: StaticString, extra: [String: TelemetryValue]) {
        let record = Report(error: error, context: "\(context)", extra: extra)
        state.withLock { $0.append(record) }
    }
}
