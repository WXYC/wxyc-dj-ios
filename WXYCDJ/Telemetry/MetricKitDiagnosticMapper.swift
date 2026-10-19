//
//  MetricKitDiagnosticMapper.swift
//  WXYCDJ
//
//  Maps the JSON representation of an MXHangDiagnostic or MXCrashDiagnostic to
//  an ExceptionEvent (issues #234 and #238). Works on JSON so fixtures can stand in for MetricKit
//  payloads, which cannot be constructed in tests, and imports no MetricKit.
//  Ported from wxyc-ios-64's mapper.
//
//  Created by Jake Bromberg on 10/19/26.
//  Copyright © 2026 WXYC. All rights reserved.
//

import Foundation

enum MetricKitDiagnosticMapper {
    /// The most frames one stack carries: a backstop that keeps the frames nearest the hang
    /// or crash site and drops the oldest. It cannot trigger on a real payload, because each frame nests
    /// two JSON levels deep and `JSONSerialization` rejects JSON nested more than 512 levels, so
    /// a stack deeper than about 254 frames is dropped at parse time.
    static let maxFrames = 256

    /// Builds an ``ExceptionEvent`` from one diagnostic's `jsonRepresentation()`.
    ///
    /// The stack is the attributed thread's (the first thread when none is attributed). A hang
    /// thread's call stack is a tree of samples, so the stack follows the most-sampled sub-frame
    /// at each level, which already runs oldest first with the hang site last, as PostHog wants.
    /// A crash thread's stack is a chain that runs the other way, so it is reversed.
    /// - Parameters:
    ///   - appBinaryName: The app's executable name. Frames in that binary are marked `in_app`.
    ///   - period: The payload's time range, which is when the diagnostic happened.
    ///   - hangDurationMilliseconds: From `MXHangDiagnostic.hangDuration`. The JSON carries it as
    ///     a localized string, so the caller passes the measurement instead.
    /// - Returns: `nil` when the JSON is malformed or carries no call stack.
    static func event(
        kind: ExceptionEvent.Kind,
        json: Data,
        appBinaryName: String? = nil,
        period: DateInterval? = nil,
        hangDurationMilliseconds: Int? = nil,
        maxFrames: Int = maxFrames
    ) -> ExceptionEvent? {
        guard let root = try? JSONSerialization.jsonObject(with: json) as? [String: Any],
              let tree = root["callStackTree"] as? [String: Any],
              let stacks = tree["callStacks"] as? [[String: Any]],
              let stack = stacks.first(where: { $0["threadAttributed"] as? Bool == true }) ?? stacks.first
        else {
            return nil
        }

        var rawFrames: [[String: Any]] = []
        var level = stack["callStackRootFrames"] as? [[String: Any]] ?? []
        while let frame = level.max(by: { sampleCount($0) < sampleCount($1) }) {
            rawFrames.append(frame)
            level = frame["subFrames"] as? [[String: Any]] ?? []
        }
        guard !rawFrames.isEmpty else {
            return nil
        }

        if kind.isReversed {
            rawFrames.reverse()
        }

        let metaData = root["diagnosticMetaData"] as? [String: Any] ?? [:]
        return ExceptionEvent(
            source: .metrickit,
            kind: kind,
            frames: rawFrames.suffix(maxFrames).map { frame(json: $0, appBinaryName: appBinaryName) },
            hangDurationMilliseconds: hangDurationMilliseconds,
            appBuild: (metaData["appBuildVersion"] as? String).flatMap { Int($0) },
            period: period,
            crash: kind == .crash ? crashDetails(metaData) : nil
        )
    }

    private static func crashDetails(_ metaData: [String: Any]) -> ExceptionEvent.CrashDetails {
        ExceptionEvent.CrashDetails(
            terminationNamespace: ExceptionEvent.TerminationNamespace(reason: metaData["terminationReason"] as? String),
            signal: (metaData["signal"] as? NSNumber)?.intValue,
            exceptionType: (metaData["exceptionType"] as? NSNumber)?.intValue,
            exceptionCode: (metaData["exceptionCode"] as? NSNumber)?.intValue
        )
    }

    private static func frame(json: [String: Any], appBinaryName: String?) -> ExceptionEvent.Frame {
        let address = (json["address"] as? NSNumber)?.uint64Value
        let binaryName = json["binaryName"] as? String
        let binaryUUID = json["binaryUUID"] as? String
        var imageAddress: UInt64?
        if let address, binaryUUID != nil, let offset = (json["offsetIntoBinaryTextSegment"] as? NSNumber)?.uint64Value, offset <= address {
            imageAddress = (address - offset) & ~0xFFF
        }
        return ExceptionEvent.Frame(
            address: address,
            binaryName: binaryName,
            binaryUUID: binaryUUID,
            imageAddress: imageAddress,
            isInApp: binaryName != nil && binaryName == appBinaryName
        )
    }

    private static func sampleCount(_ frame: [String: Any]) -> Int {
        frame["sampleCount"] as? Int ?? 0
    }
}
