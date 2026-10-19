//
//  MetricKitSubscriber.swift
//  WXYCDJ
//
//  Forwards MetricKit hang diagnostics to PostHog as `$exception` events
//  (issue #234). The one file that imports MetricKit; the mapping is the
//  MetricKit-free MetricKitDiagnosticMapper. Issue #238 adds crashes in
//  `didReceive(_:)` without a second subscriber.
//
//  Created by Jake Bromberg on 10/19/26.
//  Copyright © 2026 WXYC. All rights reserved.
//

import Foundation
import MetricKit
import os

/// Subscribes to `MXMetricManager` and reports each hang diagnostic through
/// ``PostHogErrorReporter``. Holds no mutable state, so it is `Sendable`.
final class MetricKitSubscriber: NSObject, MXMetricManagerSubscriber, Sendable {
    static let shared = MetricKitSubscriber()

    private static let log = Logger(subsystem: "org.wxyc.dj", category: "metrickit")

    private let reporter: PostHogErrorReporter

    init(reporter: PostHogErrorReporter = PostHogErrorReporter()) {
        self.reporter = reporter
    }

    /// Registers with MetricKit, which then delivers payloads on later launches too.
    func start() {
        MXMetricManager.shared.add(self)
    }

    func didReceive(_ payloads: [MXDiagnosticPayload]) {
        let appBinaryName = Bundle.main.object(forInfoDictionaryKey: "CFBundleExecutable") as? String
        for payload in payloads {
            let period = DateInterval(start: payload.timeStampBegin, end: max(payload.timeStampBegin, payload.timeStampEnd))
            for diagnostic in payload.hangDiagnostics ?? [] {
                let json = diagnostic.jsonRepresentation()
                let milliseconds = diagnostic.hangDuration.converted(to: .milliseconds).value
                guard let event = MetricKitDiagnosticMapper.event(
                    kind: .hang,
                    json: json,
                    appBinaryName: appBinaryName,
                    period: period,
                    hangDurationMilliseconds: milliseconds.isFinite ? Int(milliseconds) : nil
                ) else {
                    Self.log.error("Dropped a MetricKit hang diagnostic: its JSON (\(json.count) bytes) mapped to no event")
                    continue
                }
                reporter.report(diagnostic: event)
            }
        }
    }
}
