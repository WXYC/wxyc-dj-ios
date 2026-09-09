//
//  AlbumDetailPlaybackTests.swift
//  WXYCDJTests
//
//  Pins the pure decisions behind AlbumDetailView's issue-#145 Play section:
//  the role-plus-badge visibility gate, the 403/404/500 quiet-vs-loud
//  manifest-failure classification, the "N tracks available" wording, and
//  the now-playing/cued-album comparison. Mirrors AlbumDetailFallbackTests /
//  AlbumDetailArtworkTests — exercises the pure statics, no rendering.
//
//  Created by Jake Bromberg on 08/31/26.
//  Copyright © 2026 WXYC. All rights reserved.
//

import Testing
import WXYCAPI
@testable import WXYCDJ

@Suite("AlbumDetail digital-archive Play section")
struct AlbumDetailPlaybackTests {
    // MARK: - shouldShowDigitalAudio

    /// Catches: dropping the `hasDigitalAudio &&` half, which would show the
    /// section for an album the clone never marked as having digital audio.
    @Test("no digital audio never shows, regardless of role")
    func noDigitalAudioNeverShows() {
        #expect(AlbumDetailView.shouldShowDigitalAudio(hasDigitalAudio: false, role: nil) == false)
        #expect(AlbumDetailView.shouldShowDigitalAudio(hasDigitalAudio: false, role: "dj") == false)
    }

    /// Catches: the role gate being dropped entirely, which would show the
    /// badge/section to a `member` whose server-side role denies
    /// `digital_archive` outright.
    @Test("digital audio for a member role does not show")
    func digitalAudioForMemberDoesNotShow() {
        #expect(AlbumDetailView.shouldShowDigitalAudio(hasDigitalAudio: true, role: "member") == false)
    }

    /// Catches: the role gate being inverted (hiding every role except
    /// "member" instead of the reverse).
    @Test("digital audio for every non-member role shows", arguments: [nil, "dj", "musicDirector", "stationManager", "volunteer"] as [String?])
    func digitalAudioForNonMemberShows(role: String?) {
        #expect(AlbumDetailView.shouldShowDigitalAudio(hasDigitalAudio: true, role: role) == true)
    }

    // MARK: - classifyPlaybackManifestFailure

    /// Catches: 403 or 404 being routed to the loud arm -- both are expected
    /// states (a member's role denial, or the kill switch off / no bound
    /// audio), and must render the same quiet "No audio for this album" with
    /// no Sentry event.
    @Test("403 and 404 are quiet", arguments: [403, 404])
    func quietStatuses(status: Int) {
        let severity = AlbumDetailView.classifyPlaybackManifestFailure(.http(status: status, message: "nope"))
        #expect(severity == .quiet)
    }

    /// Catches: widening the quiet arm to "any HTTP failure" -- a 500 (e.g.
    /// `presignManifest`'s `Promise.all` rejecting the whole manifest on one
    /// misconfigured store name) must stay loud and reach Sentry.
    @Test("a 500 stays loud")
    func serverErrorIsLoud() {
        let severity = AlbumDetailView.classifyPlaybackManifestFailure(.http(status: 500, message: "boom"))
        guard case .loud = severity else {
            Issue.record("expected .loud, got \(severity)")
            return
        }
    }

    /// Catches: `.decoding`/`.network` being folded into the quiet arm,
    /// which would hide this app's own bugs (a schema mismatch, a malformed
    /// request) behind the same silence as an expected 403/404.
    @Test("decoding and network failures are loud")
    func appDefectsAreLoud() {
        guard case .loud = AlbumDetailView.classifyPlaybackManifestFailure(.decoding(detail: "bad json")) else {
            Issue.record("expected .decoding to be loud")
            return
        }
        guard case .loud = AlbumDetailView.classifyPlaybackManifestFailure(.network("timeout")) else {
            Issue.record("expected .network to be loud")
            return
        }
    }

    /// Catches: `.offline` being routed to the loud arm -- being offline is
    /// a supported mode everywhere else in this app and must never fire a
    /// Sentry event, even though the Play section also short-circuits before
    /// ever reaching the network on this leg.
    @Test(".offline is quiet")
    func offlineIsQuiet() {
        #expect(AlbumDetailView.classifyPlaybackManifestFailure(.offline(message: "no network")) == .quiet)
    }

    /// Catches: `.unauthorized`/`.notSignedIn` being routed to the loud arm.
    @Test("auth-state failures are quiet")
    func authStateFailuresAreQuiet() {
        #expect(AlbumDetailView.classifyPlaybackManifestFailure(.unauthorized) == .quiet)
        #expect(AlbumDetailView.classifyPlaybackManifestFailure(.notSignedIn) == .quiet)
    }

    // MARK: - trackAvailabilityText

    /// Catches: the pluralization being dropped (always "tracks") or the
    /// wording drifting from "N tracks available" -- deliberately never
    /// aligned with the LML Discogs tracklistSection, which is a different
    /// list from a different source (see the file header's warning).
    @Test("track availability wording", arguments: [
        (0, "0 tracks available"),
        (1, "1 track available"),
        (2, "2 tracks available"),
        (12, "12 tracks available"),
    ])
    func trackAvailabilityWording(count: Int, expected: String) {
        #expect(AlbumDetailView.trackAvailabilityText(count: count) == expected)
    }

    // MARK: - isAlbumCurrentlyCued

    /// Catches: dropping the `currentItemFileId` nil guard, which would
    /// crash or misreport "cued" with nothing playing.
    @Test("nothing cued is never the current album")
    func nothingCuedIsNeverCurrent() {
        #expect(AlbumDetailView.isAlbumCurrentlyCued(currentItemFileId: nil, trackFileIds: [201, 202]) == false)
    }

    /// Catches: the containment check being inverted or dropped.
    @Test("a cued file id belonging to this album's tracks is current")
    func cuedFileIdInThisAlbumIsCurrent() {
        #expect(AlbumDetailView.isAlbumCurrentlyCued(currentItemFileId: 202, trackFileIds: [201, 202, 203]) == true)
    }

    /// Catches: matching on the wrong field (e.g. always true once anything
    /// is cued), which would highlight this album's tracks while a
    /// different album is actually playing.
    @Test("a cued file id belonging to a different album is not current")
    func cuedFileIdInAnotherAlbumIsNotCurrent() {
        #expect(AlbumDetailView.isAlbumCurrentlyCued(currentItemFileId: 999, trackFileIds: [201, 202, 203]) == false)
    }
}
