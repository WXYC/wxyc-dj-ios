//
//  PlaybackController.swift
//  WXYCDJ
//
//  Turns a signed DigitalArchivePlaybackManifest into a queue and drives it
//  over the PlaybackEngine seam (issue #144): rendition selection, the queue
//  cursor, the requested-vs-actual transport split, the manifest-expiry
//  policy, the one-shot refetch a media 403 earns, and the cue→first-frame
//  interval issue #139 reports. No AVFoundation: everything here is a
//  decision, and every decision is exercised against SpyPlaybackEngine.
//
//  Created by Jake Bromberg on 08/30/26.
//  Copyright © 2026 WXYC. All rights reserved.
//

import Foundation
import Observation
import OSLog
import WXYCAPI

private let playbackLog = Logger(subsystem: "org.wxyc.dj", category: "playback")

/// Why playback stopped, or never started. Closed so issue #139's telemetry and
/// issue #145's UI can switch over it with no `default:`.
enum PlaybackFailure: Equatable, Sendable {
    /// The manifest was refused before anything was cued: its URLs die too
    /// soon to be worth starting an album on. See
    /// ``PlaybackController/minimumManifestLifetime``.
    case manifestExpiring
    /// No track in the manifest carried a rendition this app can play.
    case noPlayableRendition
    /// The engine gave up. Carries the engine's own closed classification.
    case engine(PlaybackEngineFailure)
    /// A media 403 earned a manifest refetch and the refetch itself failed.
    case refetchFailed
}

/// Owns the playback queue and the transport state the UI renders.
@MainActor
@Observable
final class PlaybackController {
    // MARK: - Policy constants

    /// Codec preference, most preferred first. **An `mp3` entry is not
    /// guaranteed** — `library/freeform/` holds 445 FLAC, 177 m4a and 28 wav,
    /// and Backend-Service serves all five formats through one endpoint — so
    /// selection walks this list rather than reaching for `mp3` and giving up.
    ///
    /// Ordered by cost to stream over station Wi-Fi at equal listenability:
    /// `mp3` first because it is essentially the whole archive today and the
    /// cheapest to fetch, then the two compressed AVFoundation-native formats,
    /// then the two lossless/uncompressed ones (a FLAC or wav track is an order
    /// of magnitude more bytes for a difference no DJ is auditioning a shelf
    /// copy for). `.unknownDefaultOpenApi` is deliberately absent: a codec this
    /// build has never heard of is unplayable, and falls through to the next
    /// rendition rather than crashing or being cued blind.
    ///
    /// **Caveat worth knowing before reading a passing test as a production
    /// guarantee:** the bind job as merged can only tag `mp3` — `parseId3v2`
    /// returns empty tags unless the first three bytes are literally `ID3`
    /// (m4a is `ftyp`, wav `RIFF`, flac `fLaC`) and the job carries no other
    /// container parser — so until WXYC/Backend-Service#2336 lands there are no
    /// non-mp3 `digital_asset_file` rows at all, and every non-mp3 case below
    /// is a fixture-only guarantee.
    nonisolated static let codecPreference: [DigitalArchivePlaybackRendition.Codec] = [.mp3, .aac, .m4a, .flac, .wav]

    /// How much life a manifest must have left before a queue will start on it.
    /// The server presigns for 4 hours (`DEFAULT_SIGN_TTL_SECONDS = 14400`), so
    /// this is comfortable rather than tight; it exists so a manifest fetched,
    /// left on screen, and tapped much later fails *now*, visibly, instead of
    /// three tracks in. (`expires_at` is computed after signing, so it is
    /// marginally optimistic against the URL's true expiry — irrelevant at 4h,
    /// and the reason this margin is not smaller.)
    nonisolated static let minimumManifestLifetime: TimeInterval = 600

    // MARK: - Observable state

    /// The full cued queue. Survives a refetch: a refetch replaces the URLs,
    /// never the cursor.
    private(set) var queue: [PlaybackItem] = []

    /// Index into ``queue``, or `nil` when nothing is cued (before a start,
    /// after the last item ends, after ``stop()``).
    private(set) var currentIndex: Int?

    var currentItem: PlaybackItem? {
        guard let currentIndex, queue.indices.contains(currentIndex) else { return nil }
        return queue[currentIndex]
    }

    /// What the DJ asked for. **Set synchronously by the transport calls, and
    /// deliberately not the same value as ``isPlaying``:** a transport button
    /// must render the *requested* state, because during a slow connect
    /// `isPlaying` is still `false` and a button rendering it would show "play"
    /// — so the DJ's second tap re-issues the start it meant to cancel. The
    /// listener app paid for this three times (Sentry IOS-4K/4M/4N);
    /// ``togglePlayPause()`` therefore branches on this, never on `isPlaying`.
    private(set) var isPlaybackRequested = false

    /// What the engine says is actually happening. Only ever written from
    /// ``PlaybackEngineEvent/timeControl(isPlaying:)``.
    private(set) var isPlaying = false

    /// The last position this controller commanded, in seconds; reset to zero
    /// whenever a different item is cued. The seam carries no periodic time
    /// observation (ADR 0008 keeps it to four events), so this is a commanded
    /// value, not a sampled one — a scrubber reading it gets what it last set
    /// until issue #145's engine supplies real time updates.
    private(set) var position: TimeInterval = 0

    /// The most recent failure, or `nil` if the current queue has had none.
    /// Cleared at every ``start(manifest:albumTitle:artistName:)``.
    private(set) var lastFailure: PlaybackFailure?

    /// Bumped once per manifest refetch that reaches a conclusion — including
    /// one that was superseded and deliberately discarded, which by design
    /// changes nothing else about this controller. Exposed for the same reason
    /// `AudioSessionCoordinator.deactivationSettledCount` is: a test asserting
    /// that a cancelled refetch left no trace has to wait for it to settle,
    /// and the only alternative is guessing a duration.
    private(set) var refetchSettledCount = 0

    /// How long the most recent cue took to render its first sample. Surfaced
    /// as a value rather than reported here, because issue #139 owns the
    /// analytics event and this PR ships no telemetry.
    private(set) var timeToFirstFrame: Duration?

    // MARK: - Dependencies

    @ObservationIgnored private let engine: any PlaybackEngine
    @ObservationIgnored private let api: APIClient
    /// The audio session. Optional so a controller can be unit-tested without
    /// one; `AppDependencies` wires the real coordinator.
    @ObservationIgnored private let audioSession: AudioSessionCoordinator?
    @ObservationIgnored private let reporter: any ErrorReporter
    /// Wall clock, for the ``minimumManifestLifetime`` comparison — the one
    /// thing here that genuinely compares against a server-supplied calendar
    /// instant rather than measuring an elapsed interval.
    @ObservationIgnored private let nowDate: @Sendable () -> Date
    /// Monotonic clock, for the cue→first-frame interval. `ContinuousClock` for
    /// the reasons `ConnectivityMonitor` gives: a backward wall-clock
    /// correction mid-cue would otherwise produce a negative duration.
    @ObservationIgnored private let now: @Sendable () -> ContinuousClock.Instant

    // MARK: - Private state

    @ObservationIgnored private var albumID: Int?
    @ObservationIgnored private var albumTitle = ""
    @ObservationIgnored private var artistName = ""
    @ObservationIgnored private var expiresAt: Date?
    /// Whether this queue has already spent its one manifest refetch. Reset per
    /// ``start(manifest:albumTitle:artistName:)``, mirroring `APIClient`'s
    /// per-request 401 retry-once budget rather than an unbounded one.
    @ObservationIgnored private var didRefetchManifest = false
    /// When the current cue was issued, or `nil` once its first frame landed.
    @ObservationIgnored private var cuedAt: ContinuousClock.Instant?
    @ObservationIgnored private var eventsTask: Task<Void, Never>?
    /// The in-flight refetch, cancelled by any command that supersedes it —
    /// the `SearchViewModel` discipline, applied to the one task this type
    /// starts on its own.
    @ObservationIgnored private var refetchTask: Task<Void, Never>?

    init(
        engine: any PlaybackEngine,
        api: APIClient,
        audioSession: AudioSessionCoordinator? = nil,
        reporter: any ErrorReporter = NoOpErrorReporter(),
        nowDate: @escaping @Sendable () -> Date = { Date() },
        now: @escaping @Sendable () -> ContinuousClock.Instant = { ContinuousClock.now }
    ) {
        self.engine = engine
        self.api = api
        self.audioSession = audioSession
        self.reporter = reporter
        self.nowDate = nowDate
        self.now = now
        startObservingEngine()
    }

    // MARK: - Transport

    /// Cues `manifest` and starts playing.
    ///
    /// `albumTitle` / `artistName` come from the caller because the manifest
    /// carries neither — see ``PlaybackItem``.
    ///
    /// - Returns: `false` when the queue was refused, with the reason in
    ///   ``lastFailure``.
    @discardableResult
    func start(manifest: DigitalArchivePlaybackManifest, albumTitle: String, artistName: String) -> Bool {
        lastFailure = nil
        didRefetchManifest = false
        refetchTask?.cancel()
        refetchTask = nil

        guard hasUsableLifetime(manifest) else {
            playbackLog.info("Refusing playback: manifest for album \(manifest.libraryId, privacy: .public) expires too soon")
            refuse(.manifestExpiring)
            return false
        }

        let items = Self.playbackItems(from: manifest, albumTitle: albumTitle, artistName: artistName)
        guard !items.isEmpty else {
            playbackLog.info("Refusing playback: no playable rendition for album \(manifest.libraryId, privacy: .public)")
            refuse(.noPlayableRendition)
            return false
        }

        self.albumID = manifest.libraryId
        self.albumTitle = albumTitle
        self.artistName = artistName
        self.expiresAt = manifest.expiresAt
        queue = items
        currentIndex = 0
        cue(from: 0)
        return true
    }

    /// The one transport entry point a play/pause button calls. Branches on
    /// ``isPlaybackRequested``, never on ``isPlaying`` — see that property.
    func togglePlayPause() {
        if isPlaybackRequested {
            pause()
        } else {
            resume()
        }
    }

    func pause() {
        isPlaybackRequested = false
        engine.pause()
    }

    /// Resumes the existing queue. A no-op with nothing cued, so a stray tap
    /// can't leave the transport claiming a playback nothing is backing.
    func resume() {
        guard currentItem != nil else { return }
        isPlaybackRequested = true
        audioSession?.activate()
        engine.play()
    }

    /// Skips forward. Distinct from ``PlaybackEngineEvent/itemEnded`` handling:
    /// there the engine has already advanced itself and only the cursor moves,
    /// here the engine is *told* to.
    func advance() {
        guard currentIndex != nil else { return }
        engine.advance()
        moveToNextItem()
    }

    func seek(to time: TimeInterval) {
        guard currentItem != nil else { return }
        position = time
        engine.seek(to: time)
    }

    /// Ends playback and hands the audio session back.
    func stop() {
        refetchTask?.cancel()
        refetchTask = nil
        isPlaybackRequested = false
        isPlaying = false
        cuedAt = nil
        clearQueue()
    }

    // MARK: - Rendition selection

    /// The rendition this app would play for `renditions`, or `nil` if none is
    /// playable.
    ///
    /// Walks ``codecPreference`` in order and, within a codec, takes the first
    /// rendition whose `url` parses. **Array order is the only tiebreak
    /// between two renditions of the same codec** — an album holding both
    /// `01 x.mp3` and `1-01 x.mp3` is reachable today — because
    /// `bitrate_kbps` is hardcoded `null` server-side (`fileRowOf`), so ranking
    /// on it would look natural and rank nothing.
    nonisolated static func preferredRendition(
        from renditions: [DigitalArchivePlaybackRendition]
    ) -> DigitalArchivePlaybackRendition? {
        for codec in codecPreference {
            if let match = renditions.first(where: { $0.codec == codec && URL(string: $0.url) != nil }) {
                return match
            }
        }
        return nil
    }

    /// Every track of `manifest` that has a playable rendition, in server
    /// order. A track with none is skipped rather than cued blind — the server
    /// orders `tracks` for the client, so dropping one keeps the rest playable
    /// instead of stranding the queue on it.
    nonisolated static func playbackItems(
        from manifest: DigitalArchivePlaybackManifest,
        albumTitle: String,
        artistName: String
    ) -> [PlaybackItem] {
        manifest.tracks.compactMap { track in
            guard
                let rendition = preferredRendition(from: track.renditions),
                let url = URL(string: rendition.url)
            else { return nil }
            return PlaybackItem(
                fileId: track.fileId,
                url: url,
                codec: rendition.codec,
                title: track.title,
                albumTitle: albumTitle,
                artistName: artistName,
                discNumber: track.discNumber,
                trackNumber: track.trackNumber,
                durationSecs: track.durationSecs,
                provenance: track.provenance
            )
        }
    }

    // MARK: - Engine events

    private func startObservingEngine() {
        eventsTask = Task { [weak self] in
            guard let events = self?.engine.events else { return }
            for await event in events {
                guard let self else { return }
                self.handle(event)
            }
        }
    }

    private func handle(_ event: PlaybackEngineEvent) {
        switch event {
        case .timeControl(let playing):
            isPlaying = playing
        case .itemEnded:
            moveToNextItem()
        case .firstFrame:
            guard let cuedAt else { return }
            timeToFirstFrame = now() - cuedAt
            self.cuedAt = nil
        case .failed(let failure):
            handleFailure(failure)
        }
    }

    /// Moves the cursor one item on, ending playback when it runs off the end.
    /// The engine has already advanced by the time this runs on an
    /// `.itemEnded`, which is why nothing here touches the engine.
    private func moveToNextItem() {
        guard let index = currentIndex else { return }
        let next = index + 1
        position = 0
        guard queue.indices.contains(next) else {
            currentIndex = nil
            isPlaybackRequested = false
            cuedAt = nil
            audioSession?.deactivate()
            return
        }
        currentIndex = next
        // The next item is a fresh cue, so its first frame is timed from here.
        cuedAt = now()
    }

    /// A media 403 is the one engine failure this controller can act on: the
    /// presigned URL died, and a fresh manifest mints a new one. Exactly one
    /// refetch per queue, mirroring `APIClient`'s 401 retry-once — a second
    /// 403 surfaces, because a URL that is still refused on a freshly-signed
    /// manifest is not a signature problem.
    private func handleFailure(_ failure: PlaybackEngineFailure) {
        guard failure == .mediaForbidden, !didRefetchManifest, let albumID else {
            fail(.engine(failure))
            return
        }
        didRefetchManifest = true
        refetchTask?.cancel()
        refetchTask = Task { [weak self] in
            await self?.refetchManifest(albumID: albumID)
        }
    }

    private func refetchManifest(albumID: Int) async {
        defer { refetchSettledCount += 1 }
        let resumeAt = currentIndex ?? 0
        let resumeFileID = currentItem?.fileId
        let manifest: DigitalArchivePlaybackManifest
        do {
            manifest = try await api.albumPlayback(albumId: albumID)
        } catch {
            // Cancellation arrives *here*, not at the `Task.isCancelled` check
            // below: `start()` and `stop()` both cancel this task, and a
            // cancelled request throws (`APIClient` classifies cancellation as
            // `.offline`, deliberately — see that case's doc comment). Without
            // this guard a superseded refetch resumes into a controller that
            // has since cued a *different* album and stamps `.refetchFailed`
            // over it, leaving the engine playing under a transport that reads
            // paused-with-error and a `cuedAt` cleared so the first frame never
            // times. This is the `SearchViewModel` discipline the `refetchTask`
            // doc names: the cancellation check guards the write, and the
            // failure path is a write.
            if Task.isCancelled { return }
            // A silent degrade otherwise: the DJ sees playback stop with no
            // explanation, and a systematically failing refetch (a revoked
            // bucket, a kill switch left off) is invisible without this.
            // `.offline` is excluded for the reason every other capture site
            // in this app excludes it — being offline is a supported mode,
            // not a defect.
            if case APIError.offline = error {} else {
                reporter.report(error, context: "PlaybackController.refetchManifest", extra: [:])
            }
            playbackLog.error("Playback manifest refetch failed for album \(albumID, privacy: .public)")
            fail(.refetchFailed)
            return
        }
        if Task.isCancelled { return }

        guard hasUsableLifetime(manifest) else {
            fail(.manifestExpiring)
            return
        }
        let items = Self.playbackItems(from: manifest, albumTitle: albumTitle, artistName: artistName)
        guard !items.isEmpty else {
            fail(.noPlayableRendition)
            return
        }
        expiresAt = manifest.expiresAt
        queue = items
        // Resume on the same *track*, not merely the same index: `file_id` is
        // stable across manifest refetches (the schema says so explicitly, for
        // a future offline cache key), so a refreshed manifest whose track
        // list shifted still resumes where the DJ was rather than somewhere
        // adjacent. The index is the fallback for the case the track is gone.
        let resumed = resumeFileID.flatMap { id in items.firstIndex { $0.fileId == id } }
            ?? min(resumeAt, items.count - 1)
        currentIndex = resumed
        cue(from: resumed)
    }

    // MARK: - Internals

    /// Loads the queue from `index` onward and starts it. The seam has no
    /// "load at index", so the suffix *is* the cue: the engine's queue always
    /// begins at the item the controller's cursor points to, which keeps the
    /// two from drifting across a refetch.
    private func cue(from index: Int) {
        guard queue.indices.contains(index) else { return }
        position = 0
        isPlaybackRequested = true
        cuedAt = now()
        engine.load(Array(queue[index...]))
        audioSession?.activate()
        engine.play()
    }

    private func hasUsableLifetime(_ manifest: DigitalArchivePlaybackManifest) -> Bool {
        manifest.expiresAt.timeIntervalSince(nowDate()) >= Self.minimumManifestLifetime
    }

    /// Ends the current queue: the engine stops, its queue is emptied, and
    /// the session is handed back. Shared by ``stop()`` and ``refuse(_:)`` so
    /// there is one teardown rather than two that can drift.
    private func clearQueue() {
        position = 0
        queue = []
        currentIndex = nil
        engine.pause()
        engine.load([])
        audioSession?.deactivate()
    }

    /// Records a refusal from ``start(manifest:albumTitle:artistName:)``,
    /// ending whatever was playing first.
    ///
    /// The teardown is the point. ``fail(_:)`` alone zeroes this controller's
    /// transport state without touching the engine, which is right for an
    /// engine-reported failure (the engine has already stopped) and wrong for
    /// a refusal: a DJ playing album A who taps an album B whose manifest is
    /// about to expire would be left hearing A under a transport that reads
    /// stopped, with `currentItem` still pointing at A and
    /// ``togglePlayPause()`` issuing a *second* `play()` on a queue already
    /// running. `.timeControl` only fires on transitions, so nothing would
    /// correct it. Conditional on there being a queue, so a refusal from idle
    /// still reaches the engine not at all.
    private func refuse(_ failure: PlaybackFailure) {
        if !queue.isEmpty { clearQueue() }
        fail(failure)
    }

    private func fail(_ failure: PlaybackFailure) {
        lastFailure = failure
        isPlaybackRequested = false
        isPlaying = false
        cuedAt = nil
    }
}
