//
//  ExceptionEvent.swift
//  WXYCDJ
//
//  The PostHog `$exception` event for a MetricKit diagnostic (issue #234),
//  typed to ADR 0007's contract: a closed-enum kind and source, integer and
//  date properties, and frames held as a struct rather than a free-form
//  dictionary, so a capture site that tries to attach free text does not
//  compile. Foundation only, like Analytics.swift, so WXYCDJTests reaches it
//  without linking PostHog. Hangs only; issue #238 adds the crash kind.
//
//  Created by Jake Bromberg on 10/19/26.
//  Copyright © 2026 WXYC. All rights reserved.
//

import Foundation

/// A PostHog error-tracking `$exception` built from a MetricKit diagnostic,
/// sent through ``PostHogErrorReporter/report(diagnostic:)``.
///
/// Distinct from an ``AnalyticsEvent`` because `$exception_list` and
/// `$debug_images` are nested structures no ``AnalyticsPropertyValue`` can
/// carry. The privacy contract is held by the stored types instead: nothing
/// here is a `String` a call site supplies, apart from the binary names and
/// UUIDs MetricKit puts on a frame, which are developer constants and, like
/// every string in `$exception_list`, pass through the beforeSend scrub.
struct ExceptionEvent: Sendable {
    static let name = AnalyticsPrivacyAllowlist.exceptionEventName

    /// Where the diagnostic came from. Closed, so a new source is a decision.
    enum Source: String, AnalyticsEnum {
        case metrickit
    }

    /// What kind of diagnostic it is. Issue #238 adds `crash` here, and every
    /// switch below then fails to compile until it says what a crash means.
    enum Kind: String, AnalyticsEnum {
        case hang

        /// PostHog's `$exception_level`. A hang the app recovers from is not a
        /// crash, so it is not `fatal`.
        var level: String {
            switch self {
            case .hang: "error"
            }
        }

        var exceptionType: String {
            switch self {
            case .hang: "AppHang"
            }
        }

        /// The exception's `value`. It holds only the failure kind, so one hang
        /// site groups into one issue; per-occurrence details are properties.
        var exceptionValue: String {
            switch self {
            case .hang: "App hang"
            }
        }
    }

    /// One MetricKit frame. The image load address is the frame's address minus its offset
    /// into the binary's text segment, as Sentry's MetricKit integration derives it, aligned
    /// down to the 4 KiB page. A caller frame's return address yields the image base plus one
    /// byte, where a leaf frame yields the base itself, so without the alignment two frames of
    /// one binary carry different addresses and only one matches the binary's debug image.
    struct Frame: Sendable {
        let address: UInt64?
        let binaryName: String?
        let binaryUUID: String?
        let imageAddress: UInt64?
        let isInApp: Bool

        /// PostHog reads a frame as Apple only when it says `platform: "apple"`, and
        /// symbolicates it only by matching `image_addr` to a `$debug_images` entry.
        var dictionary: [String: Any] {
            var result: [String: Any] = ["platform": "apple", "in_app": isInApp]
            if let address {
                result["instruction_addr"] = Self.hex(address)
            }
            if let binaryName {
                result["module"] = binaryName
                result["package"] = binaryName
            }
            if let imageAddress {
                result["image_addr"] = Self.hex(imageAddress)
            }
            if let binaryUUID {
                result["image_uuid"] = binaryUUID
            }
            return result
        }

        static func hex(_ address: UInt64) -> String {
            String(format: "0x%016llx", address)
        }
    }

    let source: Source
    let kind: Kind
    /// Oldest first, with the hang site last.
    let frames: [Frame]
    let hangDurationMilliseconds: Int?
    /// The diagnostic's own build number, which can predate the running one:
    /// MetricKit delivers payloads on a later launch.
    let appBuild: Int?
    let period: DateInterval?

    /// The event's properties. The non-`$` keys must be on
    /// ``AnalyticsPrivacyAllowlist/exceptionDiagnosticKeys`` (or `allowedKeys`,
    /// for `source`) or `beforeSend` drops them.
    var properties: [String: Any] {
        var result: [String: Any] = [
            "$exception_list": [[
                "type": kind.exceptionType,
                "value": kind.exceptionValue,
                "mechanism": ["type": "metrickit", "handled": false, "synthetic": false] as [String: Any],
                "stacktrace": ["type": "raw", "frames": frames.map(\.dictionary)] as [String: Any],
            ] as [String: Any]],
            "$exception_level": kind.level,
            "source": source.rawValue,
            "diagnostic_kind": kind.rawValue,
        ]
        let images = debugImages
        if !images.isEmpty {
            result["$debug_images"] = images
        }
        if let hangDurationMilliseconds {
            result["hang_duration_ms"] = hangDurationMilliseconds
        }
        if let appBuild {
            result["diagnostic_app_build"] = appBuild
        }
        if let period {
            result["diagnostic_period_start"] = period.start.formatted(.iso8601)
            result["diagnostic_period_end"] = period.end.formatted(.iso8601)
        }
        return result
    }

    /// One `macho` entry per binary the frames reference, in first-seen order.
    private var debugImages: [[String: Any]] {
        var seen = Set<String>()
        var images: [[String: Any]] = []
        for frame in frames {
            guard let uuid = frame.binaryUUID, let imageAddress = frame.imageAddress, seen.insert(uuid).inserted else {
                continue
            }
            var image: [String: Any] = ["type": "macho", "debug_id": uuid, "image_addr": Frame.hex(imageAddress)]
            if let name = frame.binaryName {
                image["code_file"] = name
            }
            images.append(image)
        }
        return images
    }
}
