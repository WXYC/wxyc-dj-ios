//
//  PlaybackControllerTests.swift
//  WXYCDJTests
//
//  Drives PlaybackController (issue #144) through SpyPlaybackEngine and
//  fixture manifests: the requested-vs-actual transport split, queue advance
//  on .itemEnded, pause/resume, the manifest-expiry refusal, the one-shot
//  refetch a media 403 earns and the failure a second one surfaces, rendition
//  selection across the five codecs the endpoint serves, and the
//  cue→first-frame interval issue #139 reports.
//
//  Every manifest here is a fixture. The bind job as merged can only tag mp3
//  (parseId3v2 returns empty tags unless the first three bytes are literally
//  `ID3`), so until WXYC/Backend-Service#2336 lands the non-mp3 selection
//  cases below are a guarantee about this app's code, not an observation
//  about production data.
//
//  Created by Jake Bromberg on 08/30/26.
//  Copyright © 2026 WXYC. All rights reserved.
//

import Foundation
import os
import Testing
@testable import WXYCAPI
@testable import WXYCDJ

@MainActor
struct PlaybackControllerTests {

    // MARK: - Cueing and the requested/actual split

    @Test("start() cues the whole queue and marks playback requested before the engine reports playing")
    func startCuesTheQueueAndRequestsPlaybackAheadOfTheEngine() async throws {
        let (api, _) = try await SignedInClient.make()
        let engine = SpyPlaybackEngine()
        let controller = PlaybackController(engine: engine, api: api)

        #expect(controller.start(manifest: PlaybackFixtures.threeTrackManifest(), albumTitle: "DOGA", artistName: "Juana Molina"))

        // The transport renders this immediately; the engine hasn't said
        // anything yet, and on a slow connect it won't for seconds.
        #expect(controller.isPlaybackRequested)
        #expect(!controller.isPlaying)
        #expect(controller.currentIndex == 0)
        #expect(controller.currentItem?.title == "la paradoja")
        #expect(controller.currentItem?.albumTitle == "DOGA")
        #expect(controller.currentItem?.artistName == "Juana Molina")
        #expect(engine.loads.count == 1)
        #expect(engine.loads[0].map(\.fileId) == [201, 202, 203])
        #expect(engine.commands.contains(.play))
    }

    @Test("a .timeControl event moves isPlaying and leaves isPlaybackRequested alone")
    func timeControlMovesIsPlayingOnly() async throws {
        let (api, _) = try await SignedInClient.make()
        let engine = SpyPlaybackEngine()
        let controller = PlaybackController(engine: engine, api: api)
        controller.start(manifest: PlaybackFixtures.threeTrackManifest(), albumTitle: "DOGA", artistName: "Juana Molina")

        engine.emit(.timeControl(isPlaying: true))
        await waitUntil { controller.isPlaying }

        #expect(controller.isPlaying)
        #expect(controller.isPlaybackRequested)
    }

    @Test("a tap during a slow connect pauses instead of re-issuing the start")
    func togglePlayPauseBranchesOnTheRequestedStateNotTheActualOne() async throws {
        let (api, _) = try await SignedInClient.make()
        let engine = SpyPlaybackEngine()
        let controller = PlaybackController(engine: engine, api: api)
        controller.start(manifest: PlaybackFixtures.threeTrackManifest(), albumTitle: "DOGA", artistName: "Juana Molina")

        // The connect is still in flight: requested, but not yet playing.
        #expect(controller.isPlaybackRequested && !controller.isPlaying)
        controller.togglePlayPause()

        #expect(!controller.isPlaybackRequested)
        #expect(engine.commands.last == .pause, "the second tap must cancel the start, not re-issue it")
        #expect(engine.commands.filter { $0 == .play }.count == 1)
    }

    @Test("pause then resume re-issues play and restores the requested state")
    func pauseThenResumeReissuesPlay() async throws {
        let (api, _) = try await SignedInClient.make()
        let engine = SpyPlaybackEngine()
        let controller = PlaybackController(engine: engine, api: api)
        controller.start(manifest: PlaybackFixtures.threeTrackManifest(), albumTitle: "DOGA", artistName: "Juana Molina")

        controller.pause()
        #expect(!controller.isPlaybackRequested)
        #expect(engine.commands.last == .pause)

        controller.resume()
        #expect(controller.isPlaybackRequested)
        #expect(engine.commands.last == .play)
        #expect(controller.currentIndex == 0, "resume must not move the cursor")
    }

    // MARK: - Queue advance

    @Test(".itemEnded advances the cursor without telling the engine to advance")
    func itemEndedAdvancesTheCursorOnly() async throws {
        let (api, _) = try await SignedInClient.make()
        let engine = SpyPlaybackEngine()
        let controller = PlaybackController(engine: engine, api: api)
        controller.start(manifest: PlaybackFixtures.threeTrackManifest(), albumTitle: "DOGA", artistName: "Juana Molina")

        engine.emit(.itemEnded)
        await waitUntil { controller.currentIndex == 1 }

        #expect(controller.currentIndex == 1)
        #expect(controller.currentItem?.fileId == 202)
        #expect(controller.isPlaybackRequested)
        #expect(!engine.commands.contains(.advance), "the engine advances its own queue on itemEnded")
    }

    @Test(".itemEnded past the last track ends playback")
    func itemEndedPastTheEndEndsPlayback() async throws {
        let (api, _) = try await SignedInClient.make()
        let engine = SpyPlaybackEngine()
        let controller = PlaybackController(engine: engine, api: api)
        controller.start(manifest: PlaybackFixtures.threeTrackManifest(), albumTitle: "DOGA", artistName: "Juana Molina")

        for _ in 0..<3 { engine.emit(.itemEnded) }
        await waitUntil { controller.currentIndex == nil }

        #expect(controller.currentIndex == nil)
        #expect(controller.currentItem == nil)
        #expect(!controller.isPlaybackRequested)
    }

    @Test("advance() tells the engine and moves the cursor")
    func advanceTellsTheEngineAndMovesTheCursor() async throws {
        let (api, _) = try await SignedInClient.make()
        let engine = SpyPlaybackEngine()
        let controller = PlaybackController(engine: engine, api: api)
        controller.start(manifest: PlaybackFixtures.threeTrackManifest(), albumTitle: "DOGA", artistName: "Juana Molina")

        controller.advance()

        #expect(engine.commands.last == .advance)
        #expect(controller.currentIndex == 1)
    }

    // MARK: - The expiry policy

    @Test("a manifest expiring inside the minimum lifetime is refused before anything is cued")
    func manifestExpiringSoonIsRefused() async throws {
        let (api, _) = try await SignedInClient.make()
        let engine = SpyPlaybackEngine()
        let clockDate = Date(timeIntervalSince1970: 1_800_000_000)
        let controller = PlaybackController(engine: engine, api: api, nowDate: { clockDate })

        let manifest = PlaybackFixtures.threeTrackManifest(expiresAt: clockDate.addingTimeInterval(5 * 60))
        #expect(controller.start(manifest: manifest, albumTitle: "DOGA", artistName: "Juana Molina") == false)

        #expect(controller.lastFailure == .manifestExpiring)
        #expect(!controller.isPlaybackRequested)
        #expect(engine.commands.isEmpty, "a refused manifest must not reach the engine at all")
    }

    @Test(
        "a manifest with at least the minimum lifetime left starts",
        arguments: [PlaybackController.minimumManifestLifetime, 14_400.0] as [TimeInterval]
    )
    func manifestWithEnoughLifetimeStarts(remaining: TimeInterval) async throws {
        let (api, _) = try await SignedInClient.make()
        let engine = SpyPlaybackEngine()
        let clockDate = Date(timeIntervalSince1970: 1_800_000_000)
        let controller = PlaybackController(engine: engine, api: api, nowDate: { clockDate })

        let manifest = PlaybackFixtures.threeTrackManifest(expiresAt: clockDate.addingTimeInterval(remaining))
        #expect(controller.start(manifest: manifest, albumTitle: "DOGA", artistName: "Juana Molina"))
        #expect(controller.lastFailure == nil)
    }

    // MARK: - The media 403 policy

    @Test("a media 403 refetches the manifest exactly once and resumes on the same track")
    func mediaForbiddenRefetchesOnceAndResumesOnTheSameTrack() async throws {
        let (api, session) = try await SignedInClient.make()
        let engine = SpyPlaybackEngine()
        let controller = PlaybackController(engine: engine, api: api)
        controller.start(manifest: PlaybackFixtures.threeTrackManifest(), albumTitle: "DOGA", artistName: "Juana Molina")

        engine.emit(.itemEnded)
        await waitUntil { controller.currentIndex == 1 }

        session.enqueue(StubRequestSession.Stub(body: PlaybackFixtures.manifestBody(PlaybackFixtures.threeTrackManifest(urlSuffix: "-refreshed"))))
        engine.emit(.failed(.mediaForbidden))
        await waitUntil { engine.loads.count == 2 }

        #expect(PlaybackFixtures.playbackRequestCount(session) == 1)
        #expect(controller.currentIndex == 1, "the refetch resumes on the track that failed")
        #expect(engine.loads[1].map(\.fileId) == [202, 203], "the engine is re-cued from the failed track, not the top of the album")
        #expect(engine.loads[1].first?.url.absoluteString.contains("-refreshed") == true, "the refetched URLs replaced the dead ones")
        #expect(controller.lastFailure == nil)
        #expect(controller.isPlaybackRequested)
    }

    @Test("a second media 403 surfaces failure instead of refetching again")
    func secondMediaForbiddenSurfacesFailure() async throws {
        let (api, session) = try await SignedInClient.make()
        let engine = SpyPlaybackEngine()
        let controller = PlaybackController(engine: engine, api: api)
        controller.start(manifest: PlaybackFixtures.threeTrackManifest(), albumTitle: "DOGA", artistName: "Juana Molina")

        session.enqueue(StubRequestSession.Stub(body: PlaybackFixtures.manifestBody(PlaybackFixtures.threeTrackManifest(urlSuffix: "-refreshed"))))
        engine.emit(.failed(.mediaForbidden))
        await waitUntil { engine.loads.count == 2 }

        engine.emit(.failed(.mediaForbidden))
        await waitUntil { controller.lastFailure != nil }

        #expect(controller.lastFailure == .engine(.mediaForbidden))
        #expect(!controller.isPlaybackRequested)
        #expect(PlaybackFixtures.playbackRequestCount(session) == 1, "the refetch budget is one per queue")
    }

    @Test("an engine failure that isn't a 403 surfaces without spending the refetch")
    func nonForbiddenFailureSurfacesWithoutRefetching() async throws {
        let (api, session) = try await SignedInClient.make()
        let engine = SpyPlaybackEngine()
        let controller = PlaybackController(engine: engine, api: api)
        controller.start(manifest: PlaybackFixtures.threeTrackManifest(), albumTitle: "DOGA", artistName: "Juana Molina")

        engine.emit(.failed(.decodeFailed))
        await waitUntil { controller.lastFailure != nil }

        #expect(controller.lastFailure == .engine(.decodeFailed))
        #expect(PlaybackFixtures.playbackRequestCount(session) == 0)
    }

    @Test("a refetch that itself fails surfaces .refetchFailed and is reported")
    func refetchFailureSurfacesAndIsReported() async throws {
        let (api, session) = try await SignedInClient.make()
        let engine = SpyPlaybackEngine()
        let reporter = SpyErrorReporter()
        let controller = PlaybackController(engine: engine, api: api, reporter: reporter)
        controller.start(manifest: PlaybackFixtures.threeTrackManifest(), albumTitle: "DOGA", artistName: "Juana Molina")

        session.enqueue(StubRequestSession.Stub(statusCode: 500, body: Data("{}".utf8)))
        engine.emit(.failed(.mediaForbidden))
        await waitUntil { controller.lastFailure != nil }

        #expect(controller.lastFailure == .refetchFailed)
        #expect(engine.loads.count == 1, "a failed refetch must not re-cue anything")
        #expect(reporter.reports.map(\.context) == ["PlaybackController.refetchManifest"])
    }

    @Test("a refetch superseded by a new start doesn't stamp its own failure over the new album")
    func refetchSupersededByANewStartIsDiscarded() async throws {
        let session = HoldingRequestSession()
        let api = try await SignedInClient.make(dataSession: session)
        let engine = SpyPlaybackEngine()
        let controller = PlaybackController(engine: engine, api: api)
        controller.start(manifest: PlaybackFixtures.threeTrackManifest(), albumTitle: "DOGA", artistName: "Juana Molina")

        engine.emit(.failed(.mediaForbidden))
        await session.waitForFirstRequest()

        // The DJ taps a different album while the refetch is still in flight.
        controller.start(
            manifest: PlaybackFixtures.manifest(libraryId: 99, tracks: [
                PlaybackFixtures.track(fileId: 901, title: "Call Your Name", renditions: [PlaybackFixtures.rendition("mp3")]),
            ]),
            albumTitle: "Edits",
            artistName: "Chuquimamani-Condori"
        )
        session.release()
        await waitUntil { controller.refetchSettledCount == 1 }

        #expect(controller.lastFailure == nil, "the superseded refetch must not stamp a failure over the new album")
        #expect(controller.isPlaybackRequested)
        #expect(controller.currentItem?.albumTitle == "Edits")
    }

    @Test("a refetch superseded by stop() records nothing")
    func refetchSupersededByStopIsDiscarded() async throws {
        let session = HoldingRequestSession()
        let api = try await SignedInClient.make(dataSession: session)
        let engine = SpyPlaybackEngine()
        let controller = PlaybackController(engine: engine, api: api)
        controller.start(manifest: PlaybackFixtures.threeTrackManifest(), albumTitle: "DOGA", artistName: "Juana Molina")

        engine.emit(.failed(.mediaForbidden))
        await session.waitForFirstRequest()
        controller.stop()
        session.release()
        await waitUntil { controller.refetchSettledCount == 1 }

        #expect(controller.lastFailure == nil, "stopping is not a refetch failure")
    }

    @Test("a refused start ends the album that was playing rather than leaving it audible")
    func refusedStartEndsThePlayingAlbum() async throws {
        let (api, _) = try await SignedInClient.make()
        let engine = SpyPlaybackEngine()
        let clockDate = Date(timeIntervalSince1970: 1_800_000_000)
        let controller = PlaybackController(engine: engine, api: api, nowDate: { clockDate })

        #expect(controller.start(
            manifest: PlaybackFixtures.threeTrackManifest(expiresAt: clockDate.addingTimeInterval(4 * 60 * 60)),
            albumTitle: "DOGA",
            artistName: "Juana Molina"
        ))

        let expiring = PlaybackFixtures.manifest(libraryId: 99, expiresAt: clockDate.addingTimeInterval(5 * 60), tracks: [
            PlaybackFixtures.track(fileId: 901, title: "Call Your Name", renditions: [PlaybackFixtures.rendition("mp3")]),
        ])
        #expect(controller.start(manifest: expiring, albumTitle: "Edits", artistName: "Chuquimamani-Condori") == false)

        #expect(controller.lastFailure == .manifestExpiring)
        // Otherwise DOGA keeps playing under a transport that reads stopped,
        // and togglePlayPause() issues a second play() on a live queue.
        #expect(controller.queue.isEmpty)
        #expect(controller.currentItem == nil)
        #expect(engine.commands.suffix(2) == [.pause, .load([])])
    }

    // MARK: - Rendition selection

    @Test(
        "selection walks the ordered codec preference",
        arguments: [
            (["wav", "mp3", "flac"], "mp3"),
            (["flac", "wav"], "flac"),
            (["wav", "m4a"], "m4a"),
            (["aac", "flac"], "aac"),
            (["wav"], "wav"),
        ]
    )
    func selectionWalksTheCodecPreference(available: [String], expected: String) {
        let renditions = available.map { PlaybackFixtures.rendition($0) }
        #expect(PlaybackController.preferredRendition(from: renditions)?.codec.rawValue == expected)
    }

    @Test("an unrecognized codec is unplayable and falls through to the next rendition")
    func unknownCodecFallsThrough() {
        let withFallback = [
            PlaybackFixtures.rendition("opus"),   // decodes to .unknownDefaultOpenApi
            PlaybackFixtures.rendition("flac"),
        ]
        #expect(PlaybackController.preferredRendition(from: withFallback)?.codec == .flac)

        let onlyUnknown = [PlaybackFixtures.rendition("opus")]
        #expect(PlaybackController.preferredRendition(from: onlyUnknown) == nil)
    }

    @Test("two renditions of the same codec are broken by array order, never by bitrate")
    func sameCodecTiebreakIsArrayOrder() {
        // Both mp3, and `bitrate_kbps` is hardcoded null server-side, so the
        // higher-numbered one carrying a bitrate must NOT win.
        let renditions = [
            PlaybackFixtures.rendition("mp3", url: "https://cdn.example.org/01%20x.mp3?sig=A"),
            PlaybackFixtures.rendition("mp3", url: "https://cdn.example.org/1-01%20x.mp3?sig=B", bitrateKbps: 320),
        ]
        #expect(PlaybackController.preferredRendition(from: renditions)?.url.hasSuffix("sig=A") == true)
    }

    @Test("a rendition whose URL doesn't parse is skipped")
    func unparseableURLIsSkipped() {
        let renditions = [
            PlaybackFixtures.rendition("mp3", url: ""),
            PlaybackFixtures.rendition("flac"),
        ]
        #expect(PlaybackController.preferredRendition(from: renditions)?.codec == .flac)
    }

    @Test("a track with no playable rendition is dropped; a manifest of nothing but those is refused")
    func unplayableTracksAreDroppedAndAnEmptyQueueIsRefused() async throws {
        let (api, _) = try await SignedInClient.make()
        let engine = SpyPlaybackEngine()
        let controller = PlaybackController(engine: engine, api: api)

        let mixed = PlaybackFixtures.manifest(tracks: [
            PlaybackFixtures.track(fileId: 301, title: "unplayable", renditions: [PlaybackFixtures.rendition("opus")]),
            PlaybackFixtures.track(fileId: 302, title: "playable", renditions: [PlaybackFixtures.rendition("flac")]),
        ])
        #expect(controller.start(manifest: mixed, albumTitle: "Edits", artistName: "Chuquimamani-Condori"))
        #expect(engine.loads[0].map(\.fileId) == [302])

        let allUnplayable = PlaybackFixtures.manifest(tracks: [
            PlaybackFixtures.track(fileId: 303, title: "unplayable", renditions: [PlaybackFixtures.rendition("opus")]),
        ])
        #expect(controller.start(manifest: allUnplayable, albumTitle: "Edits", artistName: "Chuquimamani-Condori") == false)
        #expect(controller.lastFailure == .noPlayableRendition)
    }

    @Test("provenance is carried per track, not folded to one value for the manifest")
    func provenanceIsPerTrack() {
        let manifest = PlaybackFixtures.manifest(tracks: [
            PlaybackFixtures.track(fileId: 401, title: "a", renditions: [PlaybackFixtures.rendition("mp3")], provenance: .rotationUpload),
            PlaybackFixtures.track(fileId: 402, title: "b", renditions: [PlaybackFixtures.rendition("mp3")], provenance: .cdRip),
        ])
        let items = PlaybackController.playbackItems(from: manifest, albumTitle: "DOGA", artistName: "Juana Molina")
        #expect(items.map(\.provenance) == [.rotationUpload, .cdRip])
    }

    // MARK: - Cue → first frame

    @Test("the cue→first-frame interval is recorded when the first frame lands")
    func firstFrameIntervalIsRecorded() async throws {
        let (api, _) = try await SignedInClient.make()
        let engine = SpyPlaybackEngine()
        let clock = ManualClock()
        let controller = PlaybackController(engine: engine, api: api, now: clock.reader)
        controller.start(manifest: PlaybackFixtures.threeTrackManifest(), albumTitle: "DOGA", artistName: "Juana Molina")

        #expect(controller.timeToFirstFrame == nil)
        clock.advance(by: .milliseconds(250))
        engine.emit(.firstFrame)
        await waitUntil { controller.timeToFirstFrame != nil }

        #expect(controller.timeToFirstFrame == .milliseconds(250))
    }

    // MARK: - The presigned URL is a credential

    @Test("a PlaybackItem's description omits the presigned URL")
    func playbackItemDescriptionOmitsTheURL() {
        let manifest = PlaybackFixtures.manifest(tracks: [
            PlaybackFixtures.track(
                fileId: 501,
                title: "la paradoja",
                renditions: [PlaybackFixtures.rendition("mp3", url: "https://cdn.example.org/x.mp3?X-Amz-Signature=DEADBEEF")]
            ),
        ])
        let item = try! #require(PlaybackController.playbackItems(from: manifest, albumTitle: "DOGA", artistName: "Juana Molina").first)

        #expect(!item.description.contains("DEADBEEF"))
        #expect(!item.description.contains("cdn.example.org"))
        #expect(item.description.contains("la paradoja"))
    }
}

// MARK: - Fixtures

/// Manifest fixtures. WXYC-representative material per CLAUDE.md: Juana
/// Molina's DOGA and Chuquimamani-Condori's Edits.
enum PlaybackFixtures {
    /// Four hours out, matching the server's `DEFAULT_SIGN_TTL_SECONDS`.
    static func defaultExpiry() -> Date { Date().addingTimeInterval(4 * 60 * 60) }

    static func rendition(_ codec: String, url: String = "https://cdn.example.org/track.mp3?sig=SECRET", bitrateKbps: Int? = nil) -> DigitalArchivePlaybackRendition {
        DigitalArchivePlaybackRendition(
            codec: DigitalArchivePlaybackRendition.Codec(rawValue: codec) ?? .unknownDefaultOpenApi,
            bitrateKbps: bitrateKbps,
            url: url
        )
    }

    static func track(
        fileId: Int,
        title: String,
        renditions: [DigitalArchivePlaybackRendition],
        provenance: DigitalArchivePlaybackTrack.Provenance = .rotationUpload,
        trackNumber: Int? = nil
    ) -> DigitalArchivePlaybackTrack {
        DigitalArchivePlaybackTrack(
            fileId: fileId,
            provenance: provenance,
            discNumber: 1,
            trackNumber: trackNumber,
            title: title,
            durationSecs: 214.0,
            contentHash: "d41d8cd98f00b204e9800998ecf8427e",
            renditions: renditions
        )
    }

    static func manifest(
        libraryId: Int = 4242,
        expiresAt: Date? = nil,
        tracks: [DigitalArchivePlaybackTrack]
    ) -> DigitalArchivePlaybackManifest {
        DigitalArchivePlaybackManifest(libraryId: libraryId, expiresAt: expiresAt ?? defaultExpiry(), tracks: tracks)
    }

    static func threeTrackManifest(expiresAt: Date? = nil, urlSuffix: String = "") -> DigitalArchivePlaybackManifest {
        manifest(expiresAt: expiresAt, tracks: [
            track(fileId: 201, title: "la paradoja", renditions: [rendition("mp3", url: "https://cdn.example.org/1.mp3?sig=A\(urlSuffix)")], trackNumber: 1),
            track(fileId: 202, title: "un día", renditions: [rendition("mp3", url: "https://cdn.example.org/2.mp3?sig=B\(urlSuffix)")], trackNumber: 2),
            track(fileId: 203, title: "eras", renditions: [rendition("mp3", url: "https://cdn.example.org/3.mp3?sig=C\(urlSuffix)")], trackNumber: 3),
        ])
    }

    /// The manifest as the wire carries it, for the refetch path.
    static func manifestBody(_ manifest: DigitalArchivePlaybackManifest) -> Data {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return try! encoder.encode(manifest)
    }

    /// How many `/playback` requests the client actually issued -- the auth
    /// leg shares this session, so a bare count would include the JWT
    /// exchange.
    static func playbackRequestCount(_ session: StubRequestSession) -> Int {
        session.recordedRequests.filter { $0.url?.path.hasSuffix("/playback") == true }.count
    }
}

/// A hand-advanced monotonic clock, so the cue→first-frame assertion is exact
/// rather than a tolerance around a real elapsed interval.
final class ManualClock: @unchecked Sendable {
    private let state = OSAllocatedUnfairLock(initialState: ContinuousClock.now)

    var reader: @Sendable () -> ContinuousClock.Instant {
        { [state] in state.withLock { $0 } }
    }

    func advance(by duration: Duration) {
        state.withLock { $0 = $0.advanced(by: duration) }
    }
}

/// A `RequestSession` that parks each fetch until `release()` and then throws
/// `URLError(.cancelled)` -- what `URLSession.data(for:)` does to a request
/// whose enclosing task was cancelled mid-flight. `BlockingRequestSession`
/// can't stand in: it returns a 200 on release, which exercises the
/// controller's *post*-await cancellation check rather than the catch arm
/// cancellation actually lands in.
final class HoldingRequestSession: RequestSession, @unchecked Sendable {
    private struct State {
        var released = false
        var firstRequestArrived = false
        var blocked: [CheckedContinuation<Void, Never>] = []
        var firstRequestWaiters: [CheckedContinuation<Void, Never>] = []
    }

    private let state = OSAllocatedUnfairLock(initialState: State())

    /// Suspends until at least one fetch has been entered.
    func waitForFirstRequest() async {
        await withCheckedContinuation { continuation in
            let resumeNow: Bool = state.withLock { st in
                if st.firstRequestArrived { return true }
                st.firstRequestWaiters.append(continuation)
                return false
            }
            if resumeNow { continuation.resume() }
        }
    }

    func release() {
        let toResume: [CheckedContinuation<Void, Never>] = state.withLock { st in
            st.released = true
            defer { st.blocked = [] }
            return st.blocked
        }
        for continuation in toResume { continuation.resume() }
    }

    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        let firstWaiters: [CheckedContinuation<Void, Never>] = state.withLock { st in
            guard !st.firstRequestArrived else { return [] }
            st.firstRequestArrived = true
            defer { st.firstRequestWaiters = [] }
            return st.firstRequestWaiters
        }
        for continuation in firstWaiters { continuation.resume() }

        await withCheckedContinuation { continuation in
            let resumeNow: Bool = state.withLock { st in
                if st.released { return true }
                st.blocked.append(continuation)
                return false
            }
            if resumeNow { continuation.resume() }
        }
        throw URLError(.cancelled)
    }
}

/// Polls `condition` on the main actor until it holds, yielding between
/// checks. Matches the idiom in `AudioSessionCoordinatorTests.swift`.
@MainActor
private func waitUntil(_ condition: () -> Bool) async {
    for _ in 0..<1_000 where !condition() {
        await Task.yield()
    }
}
