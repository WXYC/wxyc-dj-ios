//
//  PlaybackFailureCopyTests.swift
//  WXYCDJTests
//
//  Pins PlaybackFailureCopy (issue #151): the total, no-`default:` switch
//  from PlaybackFailure and PlaybackEngineFailure to the copy the detail
//  screen's Play section and MainView's mini-player both render. Exercises
//  every one of the six PlaybackFailure cases and all four
//  PlaybackEngineFailure cases, and pins that .emptyManifest and
//  .noPlayableRendition -- the distinction issue #144 introduced the enum to
//  preserve -- read differently.
//
//  Created by Jake Bromberg on 08/31/26.
//  Copyright © 2026 WXYC. All rights reserved.
//

import Foundation
import Testing
@testable import WXYCDJ

@Suite("PlaybackFailureCopy")
struct PlaybackFailureCopyTests {
    // MARK: - PlaybackFailure

    /// Catches: `.manifestExpiring` losing its distinct copy and falling
    /// back to the generic "Couldn't play this album." string.
    @Test("manifestExpiring names the expired link")
    func manifestExpiringNamesTheExpiredLink() {
        let message = PlaybackFailureCopy.message(for: .manifestExpiring)
        #expect(message.localizedCaseInsensitiveContains("expired"))
        #expect(message != PlaybackFailureCopy.message(for: .audioSessionUnavailable))
    }

    /// Catches: `.emptyManifest` and `.noPlayableRendition` collapsing to
    /// the same string -- the coverage-gap-vs-codec-gap distinction issue
    /// #144 introduced the enum specifically to carry through to the screen.
    @Test("emptyManifest and noPlayableRendition read differently")
    func emptyManifestAndNoPlayableRenditionDiffer() {
        let empty = PlaybackFailureCopy.message(for: .emptyManifest)
        let noRendition = PlaybackFailureCopy.message(for: .noPlayableRendition)
        #expect(empty != noRendition)
    }

    /// Catches: `.emptyManifest`'s copy drifting to something that no
    /// longer names "nothing available" -- the DJ-facing half of the
    /// coverage-gap distinction above.
    @Test("emptyManifest reads as nothing available yet")
    func emptyManifestReadsAsNothingAvailable() {
        let message = PlaybackFailureCopy.message(for: .emptyManifest)
        #expect(message.localizedCaseInsensitiveContains("nothing"))
    }

    /// Catches: `.noPlayableRendition`'s copy drifting to something that no
    /// longer names a format/capability limit.
    @Test("noPlayableRendition reads as a format limitation")
    func noPlayableRenditionReadsAsFormatLimitation() {
        let message = PlaybackFailureCopy.message(for: .noPlayableRendition)
        #expect(message.localizedCaseInsensitiveContains("format"))
    }

    /// Catches: `.engine(_)` being mapped independently of
    /// `message(for: PlaybackEngineFailure)` rather than delegating to it --
    /// which would let the two functions' copy for the same underlying
    /// engine failure drift apart.
    @Test("engine(_) delegates to the PlaybackEngineFailure mapping", arguments: [
        PlaybackEngineFailure.mediaForbidden,
        .mediaFailed,
        .decodeFailed,
        .unknown,
    ])
    func engineCaseDelegatesToEngineFailureMapping(engineFailure: PlaybackEngineFailure) {
        #expect(PlaybackFailureCopy.message(for: .engine(engineFailure)) == PlaybackFailureCopy.message(for: engineFailure))
    }

    /// Catches: `.audioSessionUnavailable` and the engine cases losing the
    /// generic "couldn't play this" treatment the issue's acceptance
    /// criteria calls for -- i.e. one of them acquiring distinct copy that
    /// silently diverges from the other's.
    @Test("audioSessionUnavailable shares the engine cases' generic copy")
    func audioSessionUnavailableSharesTheGenericCopy() {
        #expect(PlaybackFailureCopy.message(for: .audioSessionUnavailable) == PlaybackFailureCopy.message(for: .engine(.decodeFailed)))
    }

    /// Catches: `.refetchFailed` collapsing to the exact same string as
    /// `.manifestExpiring` (a refetch failure is a different fact from an
    /// unattempted, too-soon-to-start manifest).
    @Test("refetchFailed reads differently from manifestExpiring")
    func refetchFailedDiffersFromManifestExpiring() {
        #expect(PlaybackFailureCopy.message(for: .refetchFailed) != PlaybackFailureCopy.message(for: .manifestExpiring))
    }

    /// Catches: any `PlaybackFailure` case's copy embedding a URL --
    /// `PlaybackItem.url` is a bearer credential until `expires_at` and must
    /// never reach the screen. Every case is a fixed literal, so this also
    /// pins that none of them was accidentally built with string
    /// interpolation over a caller-supplied value.
    ///
    /// The markers are URL *structure*, not punctuation. `"="`, `"%"` and
    /// `"&"` were tried and removed: they are ordinary characters English copy
    /// can hold ("R&B", "50%"), so they would fail a future rewording for no
    /// privacy reason, and a signed URL's query is already caught by
    /// `Amz`/`Signature`.
    ///
    /// A scheme-prefix-only check would still catch a whole URL pasted into
    /// copy -- an earlier version of this comment claimed otherwise, which is
    /// wrong: a source literal can perfectly well contain `https://`. What it
    /// misses is a *fragment*, and `"…\(item.url.query ?? "")"` carries no
    /// scheme at all. Catching that is what the extra markers buy.
    @Test("no PlaybackFailure case's copy contains a URL", arguments: [
        PlaybackFailure.manifestExpiring,
        .emptyManifest,
        .noPlayableRendition,
        .engine(.mediaForbidden),
        .engine(.mediaFailed),
        .engine(.decodeFailed),
        .engine(.unknown),
        .refetchFailed,
        .audioSessionUnavailable,
    ])
    func copyNeverContainsAURL(failure: PlaybackFailure) {
        let message = PlaybackFailureCopy.message(for: failure)
        // Not just a scheme prefix: the dangerous shape is a *fragment* of a
        // presigned URL reaching the screen, and `item.url.query` interpolated
        // into a sentence carries no scheme at all. These markers cover the
        // query-string and percent-encoding shapes a signed S3/Spaces URL is
        // made of, so a partial leak fails here too.
        for marker in ["://", "http", "Amz", "Signature"] {
            #expect(
                !message.localizedCaseInsensitiveContains(marker),
                "copy for \(failure) contains \(marker), which is URL-shaped: \(message)"
            )
        }
    }

    // MARK: - PlaybackEngineFailure

    /// Catches: the four `PlaybackEngineFailure` cases producing different
    /// strings -- the issue's acceptance criteria calls for exactly one
    /// generic "couldn't play this" message across all of them, since none
    /// is something a DJ can act on differently from the others.
    @Test("every PlaybackEngineFailure case shares one generic message", arguments: [
        PlaybackEngineFailure.mediaForbidden,
        .mediaFailed,
        .decodeFailed,
        .unknown,
    ])
    func everyEngineFailureCaseSharesOneMessage(engineFailure: PlaybackEngineFailure) {
        #expect(PlaybackFailureCopy.message(for: engineFailure) == PlaybackFailureCopy.message(for: .mediaForbidden))
    }
}
