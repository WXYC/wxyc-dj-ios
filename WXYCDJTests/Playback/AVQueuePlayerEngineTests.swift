//
//  AVQueuePlayerEngineTests.swift
//  WXYCDJTests
//
//  AVQueuePlayerEngine (issue #145) is the documented-but-untested wiring
//  carve-out ADR 0008 Amendment 3 names -- there is no test harness in this
//  repo for driving a real AVPlayerItem to a network failure. What *is*
//  tested is the one pure decision inside it: the errorStatusCode ->
//  PlaybackEngineFailure mapping, independent of how that Int? was obtained.
//
//  Created by Jake Bromberg on 08/31/26.
//  Copyright © 2026 WXYC. All rights reserved.
//

import Testing
@testable import WXYCDJ

@Suite("AVQueuePlayerEngine.classifyFailure")
struct AVQueuePlayerEngineClassifyFailureTests {
    /// Catches: `case .some(403)` matching any other status, or being
    /// dropped so 403 falls into the `.some` catch-all.
    @Test("403 maps to mediaForbidden -- the only case PlaybackController's refetch acts on")
    func status403MapsToMediaForbidden() {
        #expect(AVQueuePlayerEngine.classifyFailure(errorStatusCode: 403) == .mediaForbidden)
    }

    /// Catches: any non-403 status being folded into `.mediaForbidden`
    /// (which would make PlaybackController spend its one-shot refetch
    /// budget on failures a fresh manifest can never fix) or into
    /// `.decodeFailed` (which would hide a real server refusal behind "the
    /// decoder rejected the bytes").
    @Test("a non-403 HTTP status maps to mediaFailed", arguments: [404, 410, 429, 500, 503])
    func otherStatusesMapToMediaFailed(status: Int) {
        #expect(AVQueuePlayerEngine.classifyFailure(errorStatusCode: status) == .mediaFailed)
    }

    /// Catches: `nil` (no HTTP-level error-log event at all) being folded
    /// into `.mediaFailed` or `.mediaForbidden` instead of `.decodeFailed`.
    @Test("no HTTP status maps to decodeFailed")
    func nilStatusMapsToDecodeFailed() {
        #expect(AVQueuePlayerEngine.classifyFailure(errorStatusCode: nil) == .decodeFailed)
    }

    /// Catches: any of the three cases above collapsing to `.unknown`, which
    /// this mapping never produces -- `.unknown` exists on
    /// `PlaybackEngineFailure` for a case this engine cannot classify at
    /// all, not for "an error occurred, with or without a status code".
    @Test("classifyFailure never returns unknown", arguments: [403, 404, 500, nil] as [Int?])
    func neverReturnsUnknown(status: Int?) {
        #expect(AVQueuePlayerEngine.classifyFailure(errorStatusCode: status) != .unknown)
    }
}
