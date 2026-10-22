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

/// Subscribes to `MXMetricManager` and reports each hang and crash diagnostic through
/// ``PostHogErrorReporter``. Holds no mutable state, so it is `Sendable`.
final class MetricKitSubscriber: NSObject, MXMetricManagerSubscriber, Sendable {
    static let shared = MetricKitSubscriber()

    /// Whether `MXCrashDiagnostic`s are forwarded. Crash forwarding exists only while
    /// PostHog's own crash autocapture is off, because Sentry's crash handler is installed
    /// (issue #233). When issue #236 turns `errorTrackingConfig.autoCapture` on, set this
    /// to `false` (or delete it and the crash loop below): otherwise every crash is
    /// reported twice, as two issues with different types and stacks.
// O5 crash-test build only (WXYC/wxyc-ios-64#1166); never merge
    static let forwardsCrashes = false

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
                let milliseconds = diagnostic.hangDuration.converted(to: .milliseconds).value
                forward(
                    .hang,
                    json: diagnostic.jsonRepresentation(),
                    appBinaryName: appBinaryName,
                    period: period,
                    hangDurationMilliseconds: milliseconds.isFinite ? Int(milliseconds) : nil
                )
            }
            if Self.forwardsCrashes {
                for diagnostic in payload.crashDiagnostics ?? [] {
                    forward(.crash, json: diagnostic.jsonRepresentation(), appBinaryName: appBinaryName, period: period)
                }
            }
        }
    }

    private func forward(
        _ kind: ExceptionEvent.Kind,
        json: Data,
        appBinaryName: String?,
        period: DateInterval,
        hangDurationMilliseconds: Int? = nil
    ) {
        guard let event = MetricKitDiagnosticMapper.event(
            kind: kind,
            json: json,
            appBinaryName: appBinaryName,
            period: period,
            hangDurationMilliseconds: hangDurationMilliseconds
        ) else {
            Self.log.error("Dropped a MetricKit \(kind.rawValue) diagnostic: its JSON (\(json.count) bytes) mapped to no event")
            return
        }
        reporter.report(diagnostic: event)
    }
}
