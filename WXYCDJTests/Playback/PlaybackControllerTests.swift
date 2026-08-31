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

import AVFoundation
import Foundation
import os
import Testing
@testable import WXYCAPI
@testable import WXYCDJ

/// Posts a real `AVAudioSession.interruptionNotification` on `center`, in
/// the same shape `PlaybackInterruptionRouteHandlerTests` uses -- this is
/// the mechanism the reason-bounded-resume tests below drive
/// `PlaybackController` through, end to end, rather than calling
/// `tearDown(reason:)`/`play(reason:)` directly.
private func postInterruption(
    _ center: NotificationCenter,
    type: AVAudioSession.InterruptionType,
    options: AVAudioSession.InterruptionOptions = []
) {
    center.post(
        name: AVAudioSession.interruptionNotification,
        object: nil,
        userInfo: [
            AVAudioSessionInterruptionTypeKey: type.rawValue,
            AVAudioSessionInterruptionOptionKey: options.rawValue,
        ]
    )
}

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
        // `fail(_:)` is a queue-ending exit, so the second `load` is the
        // teardown emptying the engine's queue -- never a re-cue of the album.
        #expect(engine.loads.last == [], "a failed refetch must not re-cue anything")
        let reCues = engine.loads.dropFirst().filter { !$0.isEmpty }
        #expect(reCues.isEmpty)
        #expect(controller.queue.isEmpty)
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

    // MARK: - Seek and position

    @Test("seek(to:) records the commanded position and tells the engine")
    func seekRecordsThePositionAndTellsTheEngine() async throws {
        let (api, _) = try await SignedInClient.make()
        let engine = SpyPlaybackEngine()
        let controller = PlaybackController(engine: engine, api: api)
        controller.start(manifest: PlaybackFixtures.threeTrackManifest(), albumTitle: "DOGA", artistName: "Juana Molina")

        controller.seek(to: 92.5)

        // Catches: deleting `position = time` from `seek(to:)`.
        #expect(controller.position == 92.5)
        #expect(engine.commands.last == .seek(92.5))
    }

    @Test("seek(to:) with nothing cued reaches neither the engine nor the position")
    func seekIsANoOpWithNothingCued() async throws {
        let (api, _) = try await SignedInClient.make()
        let engine = SpyPlaybackEngine()
        let controller = PlaybackController(engine: engine, api: api)

        controller.seek(to: 92.5)

        // Catches: deleting `guard currentItem != nil else { return }` from
        // `seek(to:)` -- a scrubber tap on an empty transport would otherwise
        // record a position no item backs and issue a seek into a dead queue.
        #expect(controller.position == 0)
        #expect(engine.commands.isEmpty)
    }

    @Test("the commanded position resets when the cursor moves to the next item")
    func positionResetsWhenTheCursorMoves() async throws {
        let (api, _) = try await SignedInClient.make()
        let engine = SpyPlaybackEngine()
        let controller = PlaybackController(engine: engine, api: api)
        controller.start(manifest: PlaybackFixtures.threeTrackManifest(), albumTitle: "DOGA", artistName: "Juana Molina")
        controller.seek(to: 92.5)

        engine.emit(.itemEnded)
        await waitUntil { controller.currentIndex == 1 }

        // Catches: deleting `position = 0` from `moveToNextItem()` -- the next
        // track would open reading 92.5 s in.
        #expect(controller.position == 0)
    }

    // MARK: - A pause that lands mid-refetch

    @Test("a pause during the one-shot refetch is not overridden when the refetch lands")
    func aPauseDuringARefetchSurvivesTheRefetch() async throws {
        let refreshed = PlaybackFixtures.manifestBody(PlaybackFixtures.threeTrackManifest(urlSuffix: "-refreshed"))
        let (api, blocking) = try await SignedInClient.makeBlocking(responseBody: refreshed)
        let engine = SpyPlaybackEngine()
        let controller = PlaybackController(engine: engine, api: api)
        controller.start(manifest: PlaybackFixtures.threeTrackManifest(), albumTitle: "DOGA", artistName: "Juana Molina")

        engine.emit(.failed(.mediaForbidden))
        await blocking.waitForFirstRequest()

        // The DJ taps pause while the refetch is still in flight.
        controller.pause()
        let playsBeforeRelease = engine.commands.filter { $0 == .play }.count
        blocking.release()
        await waitUntil { controller.refetchSettledCount == 1 }

        // Catches: restoring `cue(from:)`'s unconditional
        // `isPlaybackRequested = true` + `beginPlayback()` (i.e. dropping the
        // `startPlaying:` gate) -- audio would resume against an explicit pause.
        #expect(!controller.isPlaybackRequested)
        #expect(engine.commands.filter { $0 == .play }.count == playsBeforeRelease)
        // The recovery still happened, though: the dead URLs were replaced, so
        // a later resume() plays a live one rather than 403-ing again.
        #expect(engine.loads.count == 2)
        #expect(engine.loads[1].first?.url.absoluteString.contains("-refreshed") == true)
    }

    // MARK: - Late engine events

    @Test("a media 403 arriving after stop() neither refetches nor restarts the album")
    func aLateMediaForbiddenAfterStopIsIgnored() async throws {
        let (api, session) = try await SignedInClient.make()
        let engine = SpyPlaybackEngine()
        let controller = PlaybackController(engine: engine, api: api)
        controller.start(manifest: PlaybackFixtures.threeTrackManifest(), albumTitle: "DOGA", artistName: "Juana Molina")

        controller.stop()
        // The item being torn down reports its own failure a beat later.
        engine.emit(.failed(.mediaForbidden))
        await settle()

        // Catches: deleting `guard currentIndex != nil else { return }` from
        // `handle(_:)`'s `.failed` arm -- with the album identity also cleared
        // the failure would fall through to `fail(.engine(.mediaForbidden))`
        // and stamp a failure on a queue the DJ deliberately ended.
        #expect(controller.lastFailure == nil)
        #expect(PlaybackFixtures.playbackRequestCount(session) == 0)
        #expect(controller.queue.isEmpty)
        #expect(!controller.isPlaybackRequested)
    }

    @Test("a media 403 arriving after the queue ran out doesn't restart the album from the top")
    func aLateMediaForbiddenAfterTheQueueRanOutIsIgnored() async throws {
        let (api, session) = try await SignedInClient.make()
        let engine = SpyPlaybackEngine()
        let controller = PlaybackController(engine: engine, api: api)
        controller.start(manifest: PlaybackFixtures.threeTrackManifest(), albumTitle: "DOGA", artistName: "Juana Molina")

        for _ in 0..<3 { engine.emit(.itemEnded) }
        await waitUntil { controller.currentIndex == nil }

        session.enqueue(StubRequestSession.Stub(body: PlaybackFixtures.manifestBody(PlaybackFixtures.threeTrackManifest(urlSuffix: "-refreshed"))))
        engine.emit(.failed(.mediaForbidden))
        await settle()

        // Catches: deleting `guard currentIndex != nil else { return }` from
        // `handle(_:)`'s `.failed` arm. The album identity survives a natural
        // end-of-queue (nothing clears it there), so without the gate the
        // refetch fires and re-cues track 1 of an album that just finished.
        #expect(PlaybackFixtures.playbackRequestCount(session) == 0)
        #expect(controller.currentIndex == nil)
        #expect(!controller.isPlaybackRequested)
        #expect(engine.loads.count == 1)
    }

    @Test("a refused start doesn't leave the previous album refetchable")
    func aRefusedStartDoesNotLeaveThePreviousAlbumRefetchable() async throws {
        let (api, session) = try await SignedInClient.make()
        let engine = SpyPlaybackEngine()
        let clockDate = Date(timeIntervalSince1970: 1_800_000_000)
        let controller = PlaybackController(engine: engine, api: api, nowDate: { clockDate })

        controller.start(
            manifest: PlaybackFixtures.threeTrackManifest(expiresAt: clockDate.addingTimeInterval(4 * 60 * 60)),
            albumTitle: "DOGA",
            artistName: "Juana Molina"
        )
        let expiring = PlaybackFixtures.manifest(libraryId: 99, expiresAt: clockDate.addingTimeInterval(5 * 60), tracks: [
            PlaybackFixtures.track(fileId: 901, title: "Call Your Name", renditions: [PlaybackFixtures.rendition("mp3")]),
        ])
        #expect(controller.start(manifest: expiring, albumTitle: "Edits", artistName: "Chuquimamani-Condori") == false)

        session.enqueue(StubRequestSession.Stub(body: PlaybackFixtures.manifestBody(PlaybackFixtures.threeTrackManifest())))
        engine.emit(.failed(.mediaForbidden))
        await settle()

        // `start()` returns before assigning `albumID`, so the refusal used to
        // leave the *previous* album's id in place with a freshly-reset refetch
        // budget -- a late 403 then played DOGA again, which the DJ never asked
        // for. Catches: deleting `guard currentIndex != nil else { return }`
        // from `handle(_:)`'s `.failed` arm.
        //
        // The `lastFailure` assertion is what makes that mutation observable.
        // Without it the test passes under the deletion: `fail(.manifestExpiring)`
        // has already run `clearAlbumIdentity()`, so `handleFailure` bails at its
        // nil `albumID` and falls through to `fail(.engine(.mediaForbidden))` --
        // which issues no request, re-cues nothing, and leaves
        // `isPlaybackRequested` false, so every other assertion here still holds
        // while the refusal's own outcome has been silently overwritten.
        #expect(PlaybackFixtures.playbackRequestCount(session) == 0)
        #expect(engine.loads.last == [])
        #expect(!controller.isPlaybackRequested)
        #expect(controller.lastFailure == .manifestExpiring, "the refusal's outcome must survive the late 403")
    }

    @Test("a stray .timeControl after stop() can't claim playback on an empty queue")
    func aLateTimeControlAfterStopIsIgnored() async throws {
        let (api, _) = try await SignedInClient.make()
        let engine = SpyPlaybackEngine()
        let controller = PlaybackController(engine: engine, api: api)
        controller.start(manifest: PlaybackFixtures.threeTrackManifest(), albumTitle: "DOGA", artistName: "Juana Molina")

        // Prove the event pipeline delivers, so the assertion after the stop
        // isn't vacuously waiting on a stream nobody is draining.
        engine.emit(.timeControl(isPlaying: true))
        await waitUntil { controller.isPlaying }

        controller.stop()
        engine.emit(.timeControl(isPlaying: true))
        await settle()

        // Catches: deleting `guard !playing || currentIndex != nil else { return }`
        // from `handle(_:)`'s `.timeControl` arm. `.timeControl` only fires on
        // transitions, so nothing would ever correct `isPlaying == true` over
        // an empty queue.
        #expect(!controller.isPlaying)
        #expect(!controller.isPlaybackRequested)
    }

    // MARK: - The cursor across a refetch

    @Test("an .itemEnded landing during the refetch window isn't rewound by it")
    func anItemEndedDuringTheRefetchIsNotRewound() async throws {
        let refreshed = PlaybackFixtures.manifestBody(PlaybackFixtures.threeTrackManifest(urlSuffix: "-refreshed"))
        let (api, blocking) = try await SignedInClient.makeBlocking(responseBody: refreshed)
        let engine = SpyPlaybackEngine()
        let controller = PlaybackController(engine: engine, api: api)
        controller.start(manifest: PlaybackFixtures.threeTrackManifest(), albumTitle: "DOGA", artistName: "Juana Molina")

        engine.emit(.failed(.mediaForbidden))
        await blocking.waitForFirstRequest()

        // The engine finishes the current item while the refetch is in flight.
        engine.emit(.itemEnded)
        await waitUntil { controller.currentIndex == 1 }
        blocking.release()
        await waitUntil { engine.loads.count == 2 }

        // Catches: hoisting `resumeAt`/`resumeFileID` back above the `await` in
        // `refetchManifest(albumID:)` -- the cursor read before the suspension
        // is stale, and the queue rewinds to the track that already ended.
        #expect(controller.currentIndex == 1)
        #expect(engine.loads[1].map(\.fileId) == [202, 203])
    }

    @Test("a refetch whose track list shifted resumes on the same file_id, not the same index")
    func aRefetchWithAShiftedTrackListResumesOnTheSameFileID() async throws {
        let (api, session) = try await SignedInClient.make()
        let engine = SpyPlaybackEngine()
        let controller = PlaybackController(engine: engine, api: api)
        controller.start(manifest: PlaybackFixtures.threeTrackManifest(), albumTitle: "DOGA", artistName: "Juana Molina")

        engine.emit(.itemEnded)
        await waitUntil { controller.currentIndex == 1 }   // fileId 202

        // The refreshed manifest reorders and drops a track, so index 1 is no
        // longer the track the DJ was on -- a re-bind that merged a second
        // digital_asset does exactly this.
        let shifted = PlaybackFixtures.manifest(tracks: [
            PlaybackFixtures.track(fileId: 203, title: "eras", renditions: [PlaybackFixtures.rendition("mp3", url: "https://cdn.example.org/3.mp3?sig=C2")]),
            PlaybackFixtures.track(fileId: 201, title: "la paradoja", renditions: [PlaybackFixtures.rendition("mp3", url: "https://cdn.example.org/1.mp3?sig=A2")]),
            PlaybackFixtures.track(fileId: 202, title: "un día", renditions: [PlaybackFixtures.rendition("mp3", url: "https://cdn.example.org/2.mp3?sig=B2")]),
        ])
        session.enqueue(StubRequestSession.Stub(body: PlaybackFixtures.manifestBody(shifted)))
        engine.emit(.failed(.mediaForbidden))
        await waitUntil { engine.loads.count == 2 }

        // Catches: deleting the `resumeFileID.flatMap { … }` lookup in
        // `refetchManifest(albumID:)` and keeping only the index fallback --
        // index 1 of the refreshed list is fileId 201, a track the DJ already
        // heard, so the plain-index answer is observably different here.
        #expect(controller.currentIndex == 2)
        #expect(controller.currentItem?.fileId == 202)
        #expect(engine.loads[1].map(\.fileId) == [202])
    }

    @Test("the refetched queue carries the album and artist the original start supplied")
    func theRefetchCarriesTheAlbumAndArtistFromTheStart() async throws {
        let (api, session) = try await SignedInClient.make()
        let engine = SpyPlaybackEngine()
        let controller = PlaybackController(engine: engine, api: api)
        controller.start(manifest: PlaybackFixtures.threeTrackManifest(), albumTitle: "DOGA", artistName: "Juana Molina")

        session.enqueue(StubRequestSession.Stub(body: PlaybackFixtures.manifestBody(PlaybackFixtures.threeTrackManifest(urlSuffix: "-refreshed"))))
        engine.emit(.failed(.mediaForbidden))
        await waitUntil { engine.loads.count == 2 }

        // The manifest carries neither (ADR 0008 Amendment 4), so the refetch
        // is the only path that reads the *stored* values rather than
        // `start()`'s parameters. Catches: deleting `self.albumTitle = albumTitle`
        // (or `self.artistName = artistName`) from `start()` -- the lock screen
        // would go blank the moment a 403 was recovered from.
        #expect(engine.loads[1].allSatisfy { $0.albumTitle == "DOGA" })
        #expect(engine.loads[1].allSatisfy { $0.artistName == "Juana Molina" })
    }

    // MARK: - An empty manifest is not an unplayable one

    @Test("a manifest with no tracks is refused distinctly from one with no playable rendition")
    func anEmptyManifestIsDistinctFromAnUnplayableOne() async throws {
        let (api, _) = try await SignedInClient.make()
        let engine = SpyPlaybackEngine()
        let controller = PlaybackController(engine: engine, api: api)

        #expect(controller.start(manifest: PlaybackFixtures.manifest(tracks: []), albumTitle: "Edits", artistName: "Chuquimamani-Condori") == false)
        // Catches: deleting the `guard !manifest.tracks.isEmpty else { fail(.emptyManifest) … }`
        // from `start()` -- an album whose bind job never ran would report
        // `.noPlayableRendition`, indistinguishable from a real codec gap, and
        // the distinction can't be recovered downstream from a closed enum.
        #expect(controller.lastFailure == .emptyManifest)

        let allUnplayable = PlaybackFixtures.manifest(tracks: [
            PlaybackFixtures.track(fileId: 303, title: "unplayable", renditions: [PlaybackFixtures.rendition("opus")]),
        ])
        #expect(controller.start(manifest: allUnplayable, albumTitle: "Edits", artistName: "Chuquimamani-Condori") == false)
        #expect(controller.lastFailure == .noPlayableRendition)
        #expect(engine.commands.isEmpty)
    }

    // MARK: - The audio session

    /// Catches: dropping `beginPlayback()`'s `guard audioSession.activationPending`
    /// fast path, which would park a HARD activation failure on an observation
    /// that can never fire and report a timeout `activationWaitLimit` later.
    ///
    /// `activate()` returns `false` from three arms, not the two issue #144 and
    /// ADR 0008 Amendment 1 were written against. `.blockedBySelfHandback` and
    /// `.blockedByOtherApp` both arm something that resolves them (the pending
    /// flag, the bounded retry); `.failed` -- a `setActive(true)` that threw
    /// anything other than `CannotInterruptOthers` -- arms nothing at all, so
    /// `isActivated` can never flip. The coordinator knows this synchronously,
    /// which is why the controller must too.
    @Test("a hard activation failure fails at once instead of waiting out the ramp")
    func aHardActivationFailureFailsImmediatelyInsteadOfWaiting() async throws {
        let (api, _) = try await SignedInClient.make()
        let engine = SpyPlaybackEngine()
        let session = FakeAudioSession()
        // Not cannotInterruptOthersError(): this is the arm that schedules no
        // retry and leaves activationPending false.
        session.failAllActivations(with: NSError(domain: "org.wxyc.dj.test", code: 561_017_449))
        let coordinator = AudioSessionCoordinator(session: session, maxRetryAttempts: 4, retryDelay: .milliseconds(5))
        let controller = PlaybackController(engine: engine, api: api, audioSession: coordinator)

        controller.start(manifest: PlaybackFixtures.threeTrackManifest(), albumTitle: "DOGA", artistName: "Juana Molina")

        #expect(!coordinator.activationPending, "the .failed arm arms nothing")
        // Synchronously, with no waiting: the failure is known at t=0.
        #expect(controller.lastFailure == .audioSessionUnavailable)
        #expect(!engine.commands.contains(.play), "the engine is never started")
        #expect(!controller.isPlaybackRequested)
        #expect(controller.queue.isEmpty, "a queue-ending failure tears the queue down")
    }

    @Test("the engine is not started until a deferred audio-session activation resolves")
    func theEngineWaitsForTheActivationRamp() async throws {
        let (api, _) = try await SignedInClient.make()
        let engine = SpyPlaybackEngine()
        let session = FakeAudioSession()
        // The first activate() is refused by another app holding the session,
        // so activate() returns false ("deferred, not failed") and the
        // coordinator's bounded retry succeeds a tick later.
        session.failNextActivation(with: FakeAudioSession.cannotInterruptOthersError())
        let coordinator = AudioSessionCoordinator(session: session, maxRetryAttempts: 4, retryDelay: .milliseconds(5))
        let controller = PlaybackController(engine: engine, api: api, audioSession: coordinator)

        controller.start(manifest: PlaybackFixtures.threeTrackManifest(), albumTitle: "DOGA", artistName: "Juana Molina")

        // The transport still renders immediately -- that property is
        // load-bearing and must survive the wait (ADR 0008 Amendment 1).
        #expect(controller.isPlaybackRequested)
        #expect(engine.loads.count == 1, "the queue is cued regardless; only the start waits")
        // Catches: discarding `audioSession.activate()`'s Bool and calling
        // `engine.play()` on the next line -- the rejected alternative in ADR
        // 0008 Amendment 1, which plays into a session that isn't up and
        // produces no audio, no error, and nothing to debug.
        #expect(!engine.commands.contains(.play), "the engine must not be started while the activation is deferred")

        await waitUntil { engine.commands.contains(.play) }
        #expect(coordinator.isActivated)
        #expect(controller.lastFailure == nil)
    }

    @Test("a ramp that never resolves fails explicitly instead of silently")
    func aRampThatNeverResolvesFailsExplicitly() async throws {
        let (api, _) = try await SignedInClient.make()
        let engine = SpyPlaybackEngine()
        let reporter = SpyErrorReporter()
        let session = FakeAudioSession()
        session.failAllActivations(with: FakeAudioSession.cannotInterruptOthersError())
        let coordinator = AudioSessionCoordinator(session: session, maxRetryAttempts: 2, retryDelay: .milliseconds(5))
        let controller = PlaybackController(
            engine: engine,
            api: api,
            audioSession: coordinator,
            reporter: reporter,
            activationWaitLimit: .milliseconds(120)
        )

        controller.start(manifest: PlaybackFixtures.threeTrackManifest(), albumTitle: "DOGA", artistName: "Juana Molina")
        await waitUntil { controller.lastFailure != nil }

        // Catches: deleting the `guard didActivate else { … fail(.audioSessionUnavailable) }`
        // arm and starting the engine anyway once the bound elapses -- the
        // silent failure ADR 0008 Amendment 1 rejects.
        #expect(controller.lastFailure == .audioSessionUnavailable)
        #expect(!engine.commands.contains(.play))
        #expect(!controller.isPlaybackRequested)
        #expect(controller.queue.isEmpty, "the queue is torn down rather than left holding items nothing can play")
        #expect(reporter.reports.map(\.context) == ["PlaybackController.activation"])
    }

    @Test("resume() waits for the ramp too, not just the initial cue")
    func resumeWaitsForTheActivationRamp() async throws {
        let (api, _) = try await SignedInClient.make()
        let engine = SpyPlaybackEngine()
        let session = FakeAudioSession()
        let coordinator = AudioSessionCoordinator(session: session, maxRetryAttempts: 4, retryDelay: .milliseconds(5))
        let controller = PlaybackController(engine: engine, api: api, audioSession: coordinator)

        controller.start(manifest: PlaybackFixtures.threeTrackManifest(), albumTitle: "DOGA", artistName: "Juana Molina")
        await waitUntil { engine.commands.contains(.play) }
        controller.pause()

        // Model the session genuinely going away while paused -- an
        // interruption, or a future pause-side handback. Only the coordinator
        // owns that transition, so the test drives it directly rather than
        // inventing a controller path for it.
        coordinator.deactivate()
        await waitUntil { !coordinator.isActivated }

        // Another app grabs the session before the resume, so this activate()
        // defers exactly as the first one could.
        session.failNextActivation(with: FakeAudioSession.cannotInterruptOthersError())
        let playsBeforeResume = engine.commands.filter { $0 == .play }.count
        controller.resume()

        // Catches: replacing `resume()`'s `beginPlayback()` with the old
        // `audioSession?.activate()` + `engine.play()` pair.
        #expect(controller.isPlaybackRequested)
        #expect(engine.commands.filter { $0 == .play }.count == playsBeforeResume)
        await waitUntil { engine.commands.filter { $0 == .play }.count == playsBeforeResume + 1 }
    }

    @Test("the session is activated on cue and handed back when the queue ends")
    func theSessionIsActivatedOnCueAndHandedBackAtTheEnd() async throws {
        let (api, _) = try await SignedInClient.make()
        let engine = SpyPlaybackEngine()
        let session = FakeAudioSession()
        let coordinator = AudioSessionCoordinator(session: session)
        let controller = PlaybackController(engine: engine, api: api, audioSession: coordinator)

        controller.start(manifest: PlaybackFixtures.threeTrackManifest(), albumTitle: "DOGA", artistName: "Juana Molina")
        #expect(session.activateCallCount == 1)
        #expect(session.categoryCalls.count == 1, "the category is configured lazily, on the first activate()")

        for _ in 0..<3 { engine.emit(.itemEnded) }
        await waitUntil { controller.currentIndex == nil }
        await waitUntil { session.deactivateCallCount == 1 }

        // Catches: deleting `audioSession?.deactivate()` from
        // `moveToNextItem()`'s end-of-queue arm -- AVAudioSession would stay
        // active after the album finished, with Music/Podcasts still
        // interrupted and no transport UI to reach stop() through.
        #expect(session.deactivateCallCount == 1)
        #expect(session.setActiveCalls.last?.options == .notifyOthersOnDeactivation)
    }

    @Test("stop() hands the audio session back")
    func stopHandsTheAudioSessionBack() async throws {
        let (api, _) = try await SignedInClient.make()
        let engine = SpyPlaybackEngine()
        let session = FakeAudioSession()
        let coordinator = AudioSessionCoordinator(session: session)
        let controller = PlaybackController(engine: engine, api: api, audioSession: coordinator)

        controller.start(manifest: PlaybackFixtures.threeTrackManifest(), albumTitle: "DOGA", artistName: "Juana Molina")
        controller.stop()
        await waitUntil { session.deactivateCallCount == 1 }

        // Catches: deleting `audioSession?.deactivate()` from `clearQueue()`.
        #expect(session.deactivateCallCount == 1)
    }

    @Test("an engine failure hands the audio session back and tears the dead queue down")
    func anEngineFailureHandsTheSessionBack() async throws {
        let (api, _) = try await SignedInClient.make()
        let engine = SpyPlaybackEngine()
        let session = FakeAudioSession()
        let coordinator = AudioSessionCoordinator(session: session)
        let controller = PlaybackController(engine: engine, api: api, audioSession: coordinator)

        controller.start(manifest: PlaybackFixtures.threeTrackManifest(), albumTitle: "DOGA", artistName: "Juana Molina")
        engine.emit(.failed(.decodeFailed))
        await waitUntil { controller.lastFailure != nil }
        await waitUntil { session.deactivateCallCount == 1 }

        // Catches: deleting `if !queue.isEmpty { clearQueue() }` from `fail(_:)`.
        // `fail()` is the third queue-ending exit and was the only one that
        // never handed the session back, so a .decodeFailed left AVAudioSession
        // active indefinitely -- and left the dead URLs in `queue`, so
        // togglePlayPause() would replay them.
        #expect(session.deactivateCallCount == 1)
        #expect(controller.queue.isEmpty)
        #expect(controller.currentItem == nil)

        controller.togglePlayPause()
        #expect(!engine.commands.suffix(1).contains(.play), "there is nothing left to replay")
    }

    // MARK: - Teardown

    @Test("the engine-event consumer is cancelled when the controller goes away")
    func theEventConsumerIsCancelledWhenTheControllerDeinits() async throws {
        let (api, _) = try await SignedInClient.make()
        let engine = SpyPlaybackEngine()
        // Held in an optional and released explicitly rather than left to fall
        // out of a `do` scope: the release is the thing under test, and
        // end-of-scope lifetime is not something to take on trust in a test
        // that would otherwise pass vacuously.
        var controller: PlaybackController? = PlaybackController(engine: engine, api: api)
        controller?.start(manifest: PlaybackFixtures.threeTrackManifest(), albumTitle: "DOGA", artistName: "Juana Molina")

        // Drive one event through and wait for it to land, so the consumer is
        // provably *running and parked on the stream* before the release. Skip
        // this and the task is still queued when `deinit` cancels it: it then
        // takes its `self == nil` early return without ever iterating, the
        // stream is never consumed, and the test measures nothing -- which is
        // exactly the leak shape it is supposed to catch, only invisible.
        engine.emit(.timeControl(isPlaying: true))
        await waitUntil { controller?.isPlaying == true }
        #expect(!engine.isEventStreamTerminated)

        controller = nil
        await waitUntil { engine.isEventStreamTerminated }

        // Catches: deleting `deinit { eventsTask?.cancel() }` from
        // PlaybackController. The consumer task holds only a weak reference, so
        // a leaked one is invisible -- it just parks on the stream forever,
        // one per controller ever built.
        #expect(engine.isEventStreamTerminated)
    }

    // MARK: - Interruption resume, reason-bounded (issue #145 obligation)

    @Test("an interruption during playback pauses via tearDown, and ending it with shouldResume resumes")
    func interruptionBeginsPausesAndEndingResumes() async throws {
        let (api, _) = try await SignedInClient.make()
        let engine = SpyPlaybackEngine()
        let notificationCenter = NotificationCenter()
        let controller = PlaybackController(engine: engine, api: api, notificationCenter: notificationCenter)
        controller.start(manifest: PlaybackFixtures.threeTrackManifest(), albumTitle: "DOGA", artistName: "Juana Molina")
        engine.emit(.timeControl(isPlaying: true))
        await waitUntil { controller.isPlaying }

        postInterruption(notificationCenter, type: .began)
        // Catches: `tearDown(reason:)` not calling `engine.pause()`.
        #expect(engine.commands.last == .pause)

        postInterruption(notificationCenter, type: .ended, options: .shouldResume)

        // Catches: `tearDown(reason:)` calling `retirePendingInterruptionResume()`
        // (which it must not -- it IS the auto-resume-bearing stop) instead of
        // leaving the pending resume for `.ended` to act on.
        #expect(engine.commands.last == .play)
    }

    @Test("a manual pause during a call retires the pending resume, so the call ending does not restart playback")
    func manualPauseDuringInterruptionRetiresThePendingResume() async throws {
        let (api, _) = try await SignedInClient.make()
        let engine = SpyPlaybackEngine()
        let notificationCenter = NotificationCenter()
        let controller = PlaybackController(engine: engine, api: api, notificationCenter: notificationCenter)
        controller.start(manifest: PlaybackFixtures.threeTrackManifest(), albumTitle: "DOGA", artistName: "Juana Molina")
        engine.emit(.timeControl(isPlaying: true))
        await waitUntil { controller.isPlaying }

        postInterruption(notificationCenter, type: .began)
        #expect(engine.commands.last == .pause)

        // The DJ pauses from the Lock Screen mid-call -- a stop that is NOT
        // itself the interruption's own teardown, so it must retire the
        // pending auto-resume per the reason-bounded rule.
        controller.pause()
        let commandCountBeforeCallEnds = engine.commands.count

        postInterruption(notificationCenter, type: .ended, options: .shouldResume)

        // Catches: dropping `retirePendingInterruptionResume()` from
        // `pause()` -- without it, this call ending would re-issue `.play`
        // and restart playback the DJ had explicitly paused, which is the
        // exact field defect this obligation exists to close.
        #expect(engine.commands.count == commandCountBeforeCallEnds, "the call ending must not re-issue play after a manual pause")
    }

    @Test("stop() during an interruption retires the pending resume, so a later album is not replayed by the old call ending")
    func stopDuringInterruptionRetiresThePendingResume() async throws {
        let (api, _) = try await SignedInClient.make()
        let engine = SpyPlaybackEngine()
        let notificationCenter = NotificationCenter()
        let controller = PlaybackController(engine: engine, api: api, notificationCenter: notificationCenter)
        controller.start(manifest: PlaybackFixtures.threeTrackManifest(), albumTitle: "DOGA", artistName: "Juana Molina")
        engine.emit(.timeControl(isPlaying: true))
        await waitUntil { controller.isPlaying }

        postInterruption(notificationCenter, type: .began)
        controller.stop()

        // A different album, started fresh after the stop. Its own start()
        // already issues one .play -- if `stop()` had not retired the old
        // interruption's pending resume, the still-in-flight call ending
        // below would resume() this *new* album a second, redundant time.
        controller.start(manifest: PlaybackFixtures.threeTrackManifest(), albumTitle: "Edits", artistName: "Chuquimamani-Condori")
        let playCountAfterFreshStart = engine.commands.filter { $0 == .play }.count

        postInterruption(notificationCenter, type: .ended, options: .shouldResume)

        // Catches: dropping `retirePendingInterruptionResume()` from
        // `stop()` -- a stale interruption resume would otherwise replay a
        // later, unrelated album the moment the old call ends.
        #expect(engine.commands.filter { $0 == .play }.count == playCountAfterFreshStart, "a stale interruption resume must not replay a later, unrelated album")
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

/// Polls `condition` on the main actor until it holds or `timeout` elapses.
///
/// Yields *and* sleeps briefly between checks, unlike the fixed-yield-count
/// idiom in `AudioSessionCoordinatorTests.swift`: several of the waits here
/// depend on real elapsed time rather than on main-actor turns — the
/// coordinator's bounded retry (`retryDelay` apart), its detached handback, and
/// the controller's own activation bound — and a pure yield loop can spin
/// through its whole budget in less wall-clock time than one retry tick.
@MainActor
private func waitUntil(timeout: Duration = .seconds(5), _ condition: () -> Bool) async {
    let deadline = ContinuousClock.now.advanced(by: timeout)
    while !condition(), ContinuousClock.now < deadline {
        await Task.yield()
        try? await Task.sleep(for: .milliseconds(1))
    }
}

/// Lets every in-flight main-actor turn and short-lived task drain, for the
/// assertions that something did **not** happen.
///
/// Those can't wait on a condition — there is nothing to wait for — so they
/// need a settle point instead. Each one is paired in its test with a positive
/// observation on the same pipeline (an event that *did* land, a request count
/// the unfixed code would have raised), so the absence being asserted is a real
/// measurement rather than a vacuous one.
@MainActor
private func settle() async {
    for _ in 0..<50 { await Task.yield() }
    try? await Task.sleep(for: .milliseconds(30))
    for _ in 0..<50 { await Task.yield() }
}
