//
//  MetricKitDiagnosticMapperTests.swift
//  WXYCDJTests
//
//  Verifies a MetricKit hang diagnostic's JSON maps to a PostHog `$exception`
//  event (issue #234): the Apple frame shape PostHog accepts, one `macho`
//  debug image per binary, per-occurrence details as typed properties, and
//  property keys that clear the `$exception`-only allowlist. The fixtures are
//  ported from wxyc-ios-64's MetricKitDiagnosticMapperTests; the crash-only
//  cases (reversed stack, termination value) belong to issue #238.
//
//  Created by Jake Bromberg on 10/19/26.
//  Copyright © 2026 WXYC. All rights reserved.
//

import Foundation
import Testing
@testable import WXYCDJ

@Suite("MetricKitDiagnosticMapper")
struct MetricKitDiagnosticMapperTests {
    /// Two threads; the attributed one has a branching tree whose heavier branch must win.
    static let hangJSON = """
    {
      "callStackTree": {
        "callStackPerThread": true,
        "callStacks": [
          {
            "threadAttributed": false,
            "callStackRootFrames": [
              {"binaryUUID": "OTHER", "offsetIntoBinaryTextSegment": 1, "sampleCount": 1,
               "binaryName": "libsystem_kernel.dylib", "address": 100}
            ]
          },
          {
            "threadAttributed": true,
            "callStackRootFrames": [
              {"binaryUUID": "AAAA", "offsetIntoBinaryTextSegment": 4096, "sampleCount": 10,
               "binaryName": "WXYCDJ", "address": 4300000000,
               "subFrames": [
                 {"binaryUUID": "BBBB", "offsetIntoBinaryTextSegment": 8, "sampleCount": 2,
                  "binaryName": "UIKitCore", "address": 5000},
                 {"binaryUUID": "CCCC", "offsetIntoBinaryTextSegment": 16, "sampleCount": 8,
                  "binaryName": "Foundation", "address": 6000}
               ]}
            ]
          }
        ]
      },
      "diagnosticMetaData": {"appVersion": "3.2.1", "appBuildVersion": "412", "hangDuration": "4.2 sec"}
    }
    """

    private static func event(
        _ json: String = hangJSON,
        appBinaryName: String? = nil,
        period: DateInterval? = nil,
        hangDurationMilliseconds: Int? = nil,
        maxFrames: Int = MetricKitDiagnosticMapper.maxFrames
    ) -> ExceptionEvent? {
        MetricKitDiagnosticMapper.event(
            kind: .hang,
            json: Data(json.utf8),
            appBinaryName: appBinaryName,
            period: period,
            hangDurationMilliseconds: hangDurationMilliseconds,
            maxFrames: maxFrames
        )
    }

    @Test("A hang maps to a metrickit $exception carrying the attributed thread's heaviest path")
    func mapsHang() throws {
        let properties = try #require(Self.event()).properties

        #expect(properties["source"] as? String == "metrickit")
        #expect(properties["diagnostic_kind"] as? String == "hang")
        // A hang the app recovers from is not a crash, so it is not fatal.
        #expect(properties["$exception_level"] as? String == "error")
        let exception = try Self.exception(properties)
        #expect(exception["type"] as? String == "AppHang")
        #expect(exception["value"] as? String == "App hang")
        #expect(try Self.frames(exception).compactMap { $0["module"] as? String } == ["WXYCDJ", "Foundation"])
        #expect(ExceptionEvent.name == "$exception")
    }

    /// PostHog's error-tracking processor reads a frame as Apple only when `platform` is `apple`;
    /// without it a frame carrying `module` is read as Python and the whole event is rejected.
    @Test("Every frame has the Apple frame shape PostHog accepts")
    func framesHaveAppleShape() throws {
        let properties = try #require(Self.event(appBinaryName: "WXYCDJ")).properties
        let frames = try Self.frames(Self.exception(properties))

        for frame in frames {
            #expect(frame["platform"] as? String == "apple")
            #expect(!frame.keys.contains("debug_id"))
            #expect(!frame.keys.contains("image_offset"))
        }
        let first = try #require(frames.first)
        // address 4_300_000_000 = 0x1004ccb00; minus the 4096-byte text offset = 0x1004cbb00,
        // page-aligned to 0x1004cb000.
        #expect(first["instruction_addr"] as? String == "0x00000001004ccb00")
        #expect(first["image_addr"] as? String == "0x00000001004cb000")
        #expect(first["image_uuid"] as? String == "AAAA")
        #expect(first["package"] as? String == "WXYCDJ")
        #expect(first["in_app"] as? Bool == true)
        #expect(frames.last?["in_app"] as? Bool == false)
    }

    @Test("Debug images list each referenced binary once, keyed to the frames' image_addr")
    func debugImages() throws {
        let properties = try #require(Self.event()).properties

        let images = try #require(properties["$debug_images"] as? [[String: Any]])
        #expect(images.compactMap { $0["debug_id"] as? String } == ["AAAA", "CCCC"])
        let first = try #require(images.first)
        #expect(first["type"] as? String == "macho")
        #expect(first["code_file"] as? String == "WXYCDJ")
        #expect(first["image_addr"] as? String == "0x00000001004cb000")
    }

    @Test("Hang duration, build and the payload period are typed properties, not part of the exception value")
    func hangMetadataProperties() throws {
        let period = DateInterval(start: Date(timeIntervalSince1970: 1_800_000_000), duration: 86_400)
        let properties = try #require(Self.event(period: period, hangDurationMilliseconds: 4_200)).properties

        #expect(try Self.exception(properties)["value"] as? String == "App hang")
        #expect(properties["hang_duration_ms"] as? Int == 4_200)
        #expect(properties["diagnostic_app_build"] as? Int == 412)
        #expect(properties["diagnostic_period_start"] as? String == "2027-01-15T08:00:00Z")
        #expect(properties["diagnostic_period_end"] as? String == "2027-01-16T08:00:00Z")
    }

    @Test("A build that is not an integer is omitted rather than sent as free text")
    func nonNumericBuildIsOmitted() throws {
        let json = Self.hangJSON.replacingOccurrences(of: #""appBuildVersion": "412""#, with: #""appBuildVersion": "dj.kendra87@wxyc-test.example""#)
        let properties = try #require(Self.event(json)).properties
        #expect(properties["diagnostic_app_build"] == nil)
    }

    /// A leaf frame's address minus its text offset lands on the page-aligned image base; a caller
    /// frame's return address lands one byte past it. Both must match the binary's one debug image.
    @Test("Frames of one binary at image offset +0 and +1 share the debug image's page-aligned image_addr")
    func pageAlignsImageAddress() throws {
        let json = """
        {"callStackTree": {"callStacks": [{"threadAttributed": true, "callStackRootFrames": [
           {"binaryUUID": "APP", "offsetIntoBinaryTextSegment": 8192, "sampleCount": 1, "binaryName": "WXYCDJ", "address": 4362084352,
            "subFrames": [
              {"binaryUUID": "APP", "offsetIntoBinaryTextSegment": 12288, "sampleCount": 1, "binaryName": "WXYCDJ", "address": 4362088449}
            ]}
        ]}]}}
        """
        let properties = try #require(Self.event(json)).properties
        let frames = try Self.frames(Self.exception(properties))
        let images = try #require(properties["$debug_images"] as? [[String: Any]])

        // 0x104002000 - 0x2000 = 0x104000000 and 0x104003001 - 0x3000 = 0x104000001.
        #expect(frames.count == 2)
        #expect(frames.allSatisfy { $0["image_addr"] as? String == "0x0000000104000000" })
        #expect(images.count == 1)
        #expect(images.first?["image_addr"] as? String == "0x0000000104000000")
    }

    @Test("A hang stack deeper than the cap keeps the frames nearest the hang site, hang site last")
    func capsFrames() throws {
        var node = #"{"binaryUUID": "SITE", "offsetIntoBinaryTextSegment": 0, "sampleCount": 1, "binaryName": "WXYCDJ", "address": 1}"#
        for index in (2...40).reversed() {
            node = #"{"binaryUUID": "U\#(index)", "offsetIntoBinaryTextSegment": 0, "sampleCount": 1, "binaryName": "WXYCDJ", "address": \#(index), "subFrames": [\#(node)]}"#
        }
        let json = #"{"callStackTree": {"callStacks": [{"threadAttributed": true, "callStackRootFrames": [\#(node)]}]}}"#

        let frames = try Self.frames(Self.exception(try #require(Self.event(json, maxFrames: 16)).properties))

        #expect(frames.count == 16)
        #expect(frames.last?["image_uuid"] as? String == "SITE")
        #expect(frames.first?["image_uuid"] as? String == "U26")
    }

    @Test("Every non-$ property key is on a reviewed list, so beforeSend keeps it on $exception")
    func propertyKeysClearTheAllowlist() throws {
        let period = DateInterval(start: Date(timeIntervalSince1970: 1_800_000_000), duration: 60)
        let properties = try #require(Self.event(period: period, hangDurationMilliseconds: 1)).properties

        let filtered = AnalyticsPrivacyAllowlist.filterNonSDKProperties(properties, event: ExceptionEvent.name)
        #expect(Set(filtered.keys) == Set(properties.keys))
        let nonDollar = Set(properties.keys.filter { !$0.hasPrefix("$") })
        #expect(nonDollar.isSubset(of: AnalyticsPrivacyAllowlist.exceptionDiagnosticKeys.union(AnalyticsPrivacyAllowlist.allowedKeys)))
    }

    @Test("Malformed or stackless JSON produces no event", arguments: ["not json", "{}", #"{"callStackTree":{"callStacks":[]}}"#])
    func rejectsUnusableJSON(json: String) {
        #expect(Self.event(json) == nil)
    }

    private static func exception(_ properties: [String: Any]) throws -> [String: Any] {
        try #require((properties["$exception_list"] as? [[String: Any]])?.first)
    }

    private static func frames(_ exception: [String: Any]) throws -> [[String: Any]] {
        let stacktrace = try #require(exception["stacktrace"] as? [String: Any])
        #expect(stacktrace["type"] as? String == "raw")
        return try #require(stacktrace["frames"] as? [[String: Any]])
    }
}
