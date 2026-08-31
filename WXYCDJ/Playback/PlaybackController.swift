//
//  PlaybackController.swift
//  WXYCDJ
//
//  Turns a signed DigitalArchivePlaybackManifest into a queue and drives it
//  over the PlaybackEngine seam (issue #144): rendition selection, the queue
//  cursor, the requested-vs-actual transport split, the manifest-expiry
//  policy, the one-shot refetch a media 403 earns, the wait on a deferred
//  audio-session activation, and the cue→first-frame interval issue #139
//  reports. No AVFoundation: everything here is a decision, and every decision
//  is exercised against SpyPlaybackEngine.
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
    /// The manifest carried **no tracks at all**.
    ///
    /// Deliberately distinct from ``noPlayableRendition``, which is "this app
    /// can't play any of the formats on offer". An empty `tracks[]` means the
    /// album has no bound `digital_asset_file` rows — the bind job hasn't run
    /// for it, or its assets were cleared — which is a server-side fact about
    /// coverage, not a client-side codec limitation. Folding the two together
    /// makes an unbound album indistinguishable from an unplayable one, and
    /// because this enum is closed and issue #139's `ArchivePlaybackFailureReason`
    /// / issue #145's UI switch over it with no `default:`, a distinction not
    /// drawn here can never be recovered downstream.
    case emptyManifest
    /// No track in the manifest carried a rendition this app can play.
    case noPlayableRendition
    /// The engine gave up. Carries the engine's own closed classification.
    case engine(PlaybackEngineFailure)
    /// A media 403 earned a manifest refetch and the refetch itself failed.
    case refetchFailed
    /// The audio session never came up within
    /// ``PlaybackController/defaultActivationWaitLimit``.
    ///
    /// `AudioSessionCoordinator.activate()` returning `false` means *deferred*
    /// on two of its three false-producing arms, and neither is guaranteed to
    /// resolve in time; the third arm never resolves at all and is failed fast
    /// by ``beginPlayback()`` rather than waited on. This case covers both,
    /// and ADR 0008 Amendment 1 rejects starting the engine anyway precisely
    /// because that produces "no audio, no error, nothing to debug". This is
    /// the explicit, diagnosable alternative: the queue is torn down, the
    /// session handed back, and the give-up reported.
    case audioSessionUnavailable
}

/// Owns the playback queue and the transport state the UI renders.
///
/// Conforms to ``PlaybackInterruptionContext`` (issue #145) so its own
/// ``interruptionRouteHandler`` can drive pause/resume across a phone-call
/// interruption or a route disconnect without a second controller-shaped
/// type. See ``tearDown(reason:)`` / ``play(reason:)`` and
/// ``retirePendingInterruptionResume()`` for the reason-bounded rule that
/// keeps a Lock-Screen pause mid-call from being silently overridden when
/// the call ends.
@MainActor
@Observable
final class PlaybackController: PlaybackInterruptionContext {
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

    /// How long this controller will wait for a **deferred** audio-session
    /// activation before giving up and failing explicitly.
    ///
    /// `AudioSessionCoordinator.activate()` is synchronous and returns `false`
    /// for *deferred, not failed* on two of its three false-producing arms
    /// (ADR 0008 Amendment 1; the third is failed fast and never reaches this
    /// bound). Those two are what this limit covers, with margin: the coordinator's own
    /// bounded retry against another app holding the session
    /// (`maxRetryAttempts` 4 × `retryDelay` 250 ms = **1 s**), and its
    /// self-handback resume, which waits out a `setActive(false, …)` XPC round
    /// trip measured at **~1 s on device**. Three seconds leaves room for one
    /// of those to overlap the other (a handback landing mid-retry re-drives
    /// the activation from the continuation) without being long enough that a
    /// DJ who tapped play sits in front of an indefinite spinner: at the bound
    /// the failure is explicit — ``PlaybackFailure/audioSessionUnavailable``,
    /// logged and reported — rather than silent.
    nonisolated static let defaultActivationWaitLimit: Duration = .seconds(3)

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
    ///
    /// That is also why the post-403 refetch cannot restore the playhead: this
    /// value is what *we* asked for, not where the DJ actually was, so there
    /// is nothing here to seek back to. See ADR 0008 Amendment 5.
    private(set) var position: TimeInterval = 0

    /// The most recent failure, or `nil` if the current queue has had none.
    /// Cleared at every ``start(manifest:albumTitle:artistName:)``.
    private(set) var lastFailure: PlaybackFailure?

    /// ``PlaybackInterruptionContext`` conformance: whether playback was
    /// active immediately before the most recent route disconnect (e.g.
    /// headphones unplugged), so ``interruptionRouteHandler`` knows whether a
    /// reconnect should resume. Not rendered by any view, so
    /// `@ObservationIgnored`.
    @ObservationIgnored var wasPlayingBeforeRouteDisconnect = false

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
    /// The bound on a deferred activation — see ``defaultActivationWaitLimit``.
    /// Injected so a test can drive the give-up arm in milliseconds rather
    /// than sitting out three real seconds.
    @ObservationIgnored private let activationWaitLimit: Duration
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
    ///
    /// **A `pause()` is deliberately not one of those commands.** Pausing does
    /// not supersede the album; the DJ still wants it, and the refetch is the
    /// only thing that can make its URLs playable again — cancelling would
    /// leave the queue holding dead URLs and turn the next `resume()` into a
    /// second 403 with the refetch budget already spent. The pause is honoured
    /// by ``cue(from:startPlaying:)`` instead: the refreshed queue is loaded
    /// but not started. See ``pause()``.
    @ObservationIgnored private var refetchTask: Task<Void, Never>?
    /// The in-flight wait on a deferred audio-session activation, cancelled by
    /// anything that supersedes the start it was going to issue.
    @ObservationIgnored private var activationWaitTask: Task<Void, Never>?
    /// Owns the AVAudioSession interruption/route-change state machine
    /// (issue #138), driving this controller through the
    /// ``PlaybackInterruptionContext`` conformance below. Built at the end of
    /// `init` (once every other stored property has a value, so `self` can
    /// be handed to it) and held strongly; it holds this controller only
    /// weakly, so there is no retain cycle.
    @ObservationIgnored private var interruptionRouteHandler: PlaybackInterruptionRouteHandler?

    init(
        engine: any PlaybackEngine,
        api: APIClient,
        audioSession: AudioSessionCoordinator? = nil,
        reporter: any ErrorReporter = NoOpErrorReporter(),
        activationWaitLimit: Duration = PlaybackController.defaultActivationWaitLimit,
        nowDate: @escaping @Sendable () -> Date = { Date() },
        now: @escaping @Sendable () -> ContinuousClock.Instant = { ContinuousClock.now },
        notificationCenter: NotificationCenter = .default
    ) {
        self.engine = engine
        self.api = api
        self.audioSession = audioSession
        self.reporter = reporter
        self.activationWaitLimit = activationWaitLimit
        self.nowDate = nowDate
        self.now = now
        startObservingEngine()
        self.interruptionRouteHandler = PlaybackInterruptionRouteHandler(
            notificationCenter: notificationCenter,
            context: self
        )
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
        // Forget the outgoing album *before* the guards, not after. Both
        // refusal arms below `return` early, and the assignment they used to
        // return ahead of was the only thing that moved `albumID` on — so a
        // refused start left the **previous** album's id in place beside a
        // freshly-reset refetch budget, and a late `.mediaForbidden` from the
        // album being torn down would then refetch and play an album the DJ
        // had just navigated away from.
        clearAlbumIdentity()
        cancelActivationWait()

        guard hasUsableLifetime(manifest) else {
            playbackLog.info("Refusing playback: manifest for album \(manifest.libraryId, privacy: .public) expires too soon")
            fail(.manifestExpiring)
            return false
        }

        // An empty `tracks[]` is a coverage fact, not a codec one -- see
        // ``PlaybackFailure/emptyManifest``. Checked before selection so the
        // two never collapse into one indistinguishable refusal.
        guard !manifest.tracks.isEmpty else {
            playbackLog.info("Refusing playback: manifest for album \(manifest.libraryId, privacy: .public) carries no tracks")
            fail(.emptyManifest)
            return false
        }

        let items = Self.playbackItems(from: manifest, albumTitle: albumTitle, artistName: artistName)
        guard !items.isEmpty else {
            playbackLog.info("Refusing playback: no playable rendition for album \(manifest.libraryId, privacy: .public)")
            fail(.noPlayableRendition)
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

    /// Pauses, and withdraws any start this controller was still waiting to
    /// issue.
    ///
    /// Two of those are in flight-able and both used to outlive the pause. The
    /// **activation wait** is cancelled outright — the engine start it was
    /// going to make is exactly what the DJ just cancelled. The **one-shot 403
    /// refetch** is deliberately left running: it is not superseded by a pause
    /// (see ``refetchTask``), and its re-cue reads ``isPlaybackRequested`` so
    /// it loads the refreshed queue without starting it.
    func pause() {
        isPlaybackRequested = false
        cancelActivationWait()
        retirePendingInterruptionResume()
        engine.pause()
    }

    /// Resumes the existing queue. A no-op with nothing cued, so a stray tap
    /// can't leave the transport claiming a playback nothing is backing.
    func resume() {
        guard currentItem != nil else { return }
        isPlaybackRequested = true
        beginPlayback()
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
        clearAlbumIdentity()
        cancelActivationWait()
        retirePendingInterruptionResume()
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

    /// Routes one engine event.
    ///
    /// **Every arm is gated on there being a live cursor**, because an engine
    /// tearing an item down reports on it *after* this controller has moved
    /// on, and two of the four arms are writes that nothing would ever
    /// correct. `.itemEnded` and `.firstFrame` carried their own guards from
    /// the start; `.timeControl` and `.failed` are the two this closed later.
    private func handle(_ event: PlaybackEngineEvent) {
        switch event {
        case .timeControl(let playing):
            // A `false` is always safe to apply -- it can only ever agree with
            // an empty queue. A `true` is not: a yield arriving after `stop()`
            // would claim playback with `isPlaybackRequested == false` and
            // `currentItem == nil`, and `.timeControl` only fires on
            // *transitions*, so no later event would ever put it right.
            guard !playing || currentIndex != nil else { return }
            isPlaying = playing
        case .itemEnded:
            moveToNextItem()
        case .firstFrame:
            guard let cuedAt else { return }
            timeToFirstFrame = now() - cuedAt
            self.cuedAt = nil
        case .failed(let failure):
            // The costliest of the four to act on late: a `.mediaForbidden`
            // from an item being discarded would spend the refetch budget and
            // re-cue an album the DJ has already stopped, been refused off, or
            // played to the end -- restarting audio and re-activating the
            // audio session that was just handed back.
            guard currentIndex != nil else { return }
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
            // Nothing is playing once the queue runs out, and `.timeControl`
            // fires only on transitions -- so the engine's own `false` may
            // never arrive, and (since `handle(_:)` now refuses a `true` over
            // an empty queue) could not be applied if it did.
            isPlaying = false
            cuedAt = nil
            cancelActivationWait()
            retirePendingInterruptionResume()
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
        guard !manifest.tracks.isEmpty else {
            fail(.emptyManifest)
            return
        }
        let items = Self.playbackItems(from: manifest, albumTitle: albumTitle, artistName: artistName)
        guard !items.isEmpty else {
            fail(.noPlayableRendition)
            return
        }

        // **The cursor is read here, after the `await`, and never before it.**
        // A refetch is a suspension the rest of this controller keeps running
        // across: an `.itemEnded`, an `advance()`, or a `pause()` can all land
        // in that window, and a cursor snapshotted at the top would be stale
        // by the time it was applied -- silently rewinding the queue to a
        // track that had already finished. This is the same shape, and the
        // same answer, as `AuthService.refreshJWT` re-checking `sessionEpoch`
        // on its success path and `currentJWT` re-checking token identity:
        // `Task.isCancelled` cannot stand in for it, because none of those
        // three commands cancels this task.
        guard let resumeAt = currentIndex else {
            // The queue ran out while the refetch was in flight. There is
            // nothing to resume, and re-cueing from the top would restart an
            // album the DJ has already finished.
            return
        }
        let resumeFileID = currentItem?.fileId

        expiresAt = manifest.expiresAt
        queue = items
        // Resume on the same *track*, not merely the same index: `file_id` is
        // stable across manifest refetches (the schema says so explicitly, for
        // a future offline cache key), so a refreshed manifest whose track
        // list shifted still resumes on the track the DJ was on rather than on
        // whatever now sits at that array index. The index is the fallback for
        // the case the track is gone. **It resumes the track, not the
        // playhead** -- the recovered track restarts from 0:00, because this
        // seam carries no time to seek back to; see ADR 0008 Amendment 5 and
        // issue #145.
        let resumed = resumeFileID.flatMap { id in items.firstIndex { $0.fileId == id } }
            ?? min(resumeAt, items.count - 1)
        currentIndex = resumed
        // A `pause()` that landed in the refetch window is honoured: the
        // refreshed queue is loaded (so a later `resume()` plays a live URL
        // rather than the dead one that 403'd) but not started.
        cue(from: resumed, startPlaying: isPlaybackRequested)
    }

    // MARK: - Internals

    /// Loads the queue from `index` onward and, unless `startPlaying` is
    /// `false`, starts it. The seam has no "load at index", so the suffix *is*
    /// the cue: the engine's queue always begins at the item the controller's
    /// cursor points to, which keeps the two from drifting across a refetch.
    ///
    /// `startPlaying: false` is the post-403 re-cue arriving after the DJ
    /// paused — the queue must be refreshed (its old URLs are dead) without
    /// audio resuming against an explicit pause. `cuedAt` is left `nil` there
    /// because nothing was started, so no first frame is coming to time.
    private func cue(from index: Int, startPlaying: Bool = true) {
        guard queue.indices.contains(index) else { return }
        position = 0
        engine.load(Array(queue[index...]))
        guard startPlaying else {
            cuedAt = nil
            return
        }
        isPlaybackRequested = true
        cuedAt = now()
        beginPlayback()
    }

    /// Starts the engine, waiting first if the audio session's activation was
    /// deferred.
    ///
    /// `AudioSessionCoordinator.activate()` is synchronous and prompt, and a
    /// `false` from it means **deferred, not failed** on two of its three
    /// false-producing arms (another app holds the session; this coordinator's
    /// own handback is mid-flight) and those two self-resolve. The third,
    /// `.failed`, arms nothing and is failed fast below. Playing anyway is the alternative
    /// ADR 0008 Amendment 1 records as *rejected*: it produces no audio, no
    /// error, and nothing to debug. So a `false` parks the start on
    /// ``waitForActivation(_:limit:)`` instead, bounded by
    /// ``defaultActivationWaitLimit``.
    ///
    /// What does **not** move: ``isPlaybackRequested`` is already `true` by the
    /// time this runs, set synchronously by the transport call, so a tap still
    /// renders at once. And the handback resume stays the coordinator's own
    /// business — this reads ``AudioSessionCoordinator/isActivated`` and never
    /// drives it.
    private func beginPlayback() {
        cancelActivationWait()
        guard let audioSession else {
            engine.play()
            return
        }
        if audioSession.activate() {
            engine.play()
            return
        }
        // A `false` is only a *deferral* when the coordinator armed something
        // that will resolve it: `.blockedBySelfHandback` sets
        // `activationPending` directly and `.blockedByOtherApp` sets it via
        // `scheduleRetry()`. Its third false-producing arm, `.failed` (a
        // `setActive(true)` that threw something other than
        // `CannotInterruptOthers` -- a mediaservices reset, `!pri`, resource
        // busy), arms **nothing**: no retry, no pending flag, and `isActivated`
        // stays false forever. Waiting on an observation that can never fire
        // would spend the whole `activationWaitLimit` and then report a
        // *timeout* for a failure the coordinator already knew about
        // synchronously, at t=0, and has already logged and reported through
        // its own `ErrorReporter`.
        //
        // The "two states produce a false, and both self-resolve" claim that
        // issue #144 and ADR 0008 Amendment 1 were written against is wrong;
        // `AudioSessionCoordinatorTests.hardActivationFailureDoesNotScheduleARetry`
        // pins the third. Both arrive here as `.audioSessionUnavailable`,
        // which is true of each -- the cause is the coordinator's to report.
        guard audioSession.activationPending else {
            fail(.audioSessionUnavailable)
            return
        }
        let limit = activationWaitLimit
        activationWaitTask = Task { [weak self] in
            let didActivate = await Self.waitForActivation(audioSession, limit: limit)
            guard !Task.isCancelled else { return }
            self?.finishDeferredActivation(didActivate: didActivate)
        }
    }

    /// Suspends until `session` reports itself active, or `limit` elapses.
    ///
    /// Observation, not polling: `isActivated` is the one tracked property on
    /// the coordinator and exists for exactly this (ADR 0008 Amendment 1). The
    /// timeout rides a sleeping task the change callback *cancels*, rather
    /// than a second racer in a task group — a group awaits all its children
    /// before returning, and an observation callback that never fires would
    /// leave one parked forever.
    ///
    /// `onChange` fires on the *will*-set, so the value is re-read afterwards
    /// rather than assumed: both writers of `isActivated` are main-actor
    /// isolated, so by the time this `@MainActor` waiter is resumed the write
    /// (and anything else in that same turn — a handback continuation clears
    /// the flag and then re-drives the deferred activation, both before it
    /// yields) has completed. Hence the loop rather than a single wait.
    @MainActor
    private static func waitForActivation(_ session: AudioSessionCoordinator, limit: Duration) async -> Bool {
        let deadline = ContinuousClock.now.advanced(by: limit)
        while !session.isActivated {
            let remaining = ContinuousClock.now.duration(to: deadline)
            guard remaining > .zero else { return false }
            let sleeper = Task { @MainActor in try? await Task.sleep(for: remaining) }
            withObservationTracking {
                _ = session.isActivated
            } onChange: {
                sleeper.cancel()
            }
            await withTaskCancellationHandler {
                await sleeper.value
            } onCancel: {
                sleeper.cancel()
            }
            if Task.isCancelled { return false }
        }
        return true
    }

    /// Applies the outcome of a deferred activation.
    ///
    /// The give-up arm is the point: it is explicit and diagnosable — the
    /// queue torn down, the session handed back, ``PlaybackFailure/audioSessionUnavailable``
    /// recorded, the give-up reported — rather than starting the engine anyway
    /// and reproducing the silence ADR 0008 Amendment 1 rejects three seconds
    /// later.
    private func finishDeferredActivation(didActivate: Bool) {
        activationWaitTask = nil
        // Superseded while we waited: a pause, a stop, a different album, or a
        // failure. Nothing here is that caller's to undo.
        guard isPlaybackRequested, currentItem != nil else { return }
        guard didActivate else {
            playbackLog.error("Audio session never activated; abandoning playback")
            reporter.report(AudioSessionActivationTimeout(), context: "PlaybackController.activation", extra: [:])
            fail(.audioSessionUnavailable)
            return
        }
        engine.play()
    }

    /// The error the give-up above reports. A bare type name, deliberately
    /// carrying no payload: `SentryErrorReporter` renders an uncurated error
    /// through `String(describing:)`, and there is nothing about this failure
    /// worth naming that a presigned URL or a server string could ride along
    /// with.
    private struct AudioSessionActivationTimeout: Error {}

    private func cancelActivationWait() {
        activationWaitTask?.cancel()
        activationWaitTask = nil
    }

    private func hasUsableLifetime(_ manifest: DigitalArchivePlaybackManifest) -> Bool {
        manifest.expiresAt.timeIntervalSince(nowDate()) >= Self.minimumManifestLifetime
    }

    /// Forgets which album the queue belongs to, and drops the refetch that
    /// only made sense for it.
    ///
    /// Shared by ``start(manifest:albumTitle:artistName:)``, ``stop()`` and
    /// ``fail(_:)``, so no exit can leave `albumID` pointing at an album this
    /// controller has moved off while `didRefetchManifest` is reset to a fresh
    /// budget — the pairing that let a late `.mediaForbidden` refetch and play
    /// something the DJ never asked for. `handle(_:)`'s live-cursor gate closes
    /// the same door from the other side; both are cheap and neither is a
    /// reason to drop the other.
    private func clearAlbumIdentity() {
        albumID = nil
        expiresAt = nil
        didRefetchManifest = false
        refetchTask?.cancel()
        refetchTask = nil
    }

    /// Ends the current queue: the engine stops, its queue is emptied, and
    /// the session is handed back. Shared by ``stop()`` and ``fail(_:)`` so
    /// there is one teardown rather than two that can drift.
    private func clearQueue() {
        position = 0
        queue = []
        currentIndex = nil
        engine.pause()
        engine.load([])
        audioSession?.deactivate()
    }

    /// Records a failure and ends the queue it belonged to.
    ///
    /// **The teardown is not optional, and it is what this used to be missing.**
    /// This is one of the three queue-ending exits — the other two being
    /// `moveToNextItem()`'s end-of-queue arm and a start refused before
    /// anything was cued — and it was the only one that never handed the audio
    /// session back. A `.decodeFailed`, a second `.mediaForbidden`, or a
    /// `.refetchFailed` therefore left `AVAudioSession` active indefinitely,
    /// with Music/Podcasts still interrupted and (no transport UI shipped) no
    /// way for a DJ to reach ``stop()``. It also left `queue`/`currentItem`
    /// populated with URLs known to be dead, so ``togglePlayPause()`` would
    /// replay them.
    ///
    /// The teardown is conditional on there being a queue, so a refusal from
    /// idle still reaches the engine not at all — the property
    /// `start(manifest:albumTitle:artistName:)`'s refusal arms need, since a DJ
    /// playing album A who taps an about-to-expire album B must stop hearing A
    /// rather than be left with a transport that reads stopped over a queue
    /// still running.
    private func fail(_ failure: PlaybackFailure) {
        clearAlbumIdentity()
        cancelActivationWait()
        retirePendingInterruptionResume()
        if !queue.isEmpty { clearQueue() }
        lastFailure = failure
        isPlaybackRequested = false
        isPlaying = false
        cuedAt = nil
    }

    /// Retires any pending post-interruption auto-resume the interruption
    /// handler is holding (``PlaybackInterruptionRouteHandler/cancelPendingInterruptionResume()``).
    ///
    /// **The reason-bounded rule (standing obligation from issue #138,
    /// discharged here):** every controller-initiated teardown calls this
    /// -- ``pause()``, ``stop()``, ``fail(_:)``, and the end-of-queue arm of
    /// ``moveToNextItem()`` -- **except** ``tearDown(reason:)``, which *is*
    /// the auto-resume-bearing stop the interruption handler itself asks
    /// for. Calling this from `tearDown(reason:)` would erase the very flag
    /// the handler just set (`wasPlayingBeforeInterruption`, assigned
    /// immediately before it calls `context.tearDown(reason: .interruptionBegan)`),
    /// which would make an interruption that both begins *and* ends never
    /// resume at all. Every *other* stop must retire it, or a DJ who pauses
    /// from the Lock Screen mid-call has playback restart on them the moment
    /// the call ends -- the defect this method exists to close.
    private func retirePendingInterruptionResume() {
        interruptionRouteHandler?.cancelPendingInterruptionResume()
    }

    // MARK: - PlaybackInterruptionContext

    /// Pauses for an interruption/route-disconnect reason, **without**
    /// retiring the pending auto-resume -- see
    /// ``retirePendingInterruptionResume()``'s doc comment for why this is
    /// the one teardown that must not call it. Deliberately not routed
    /// through ``pause()``: the only difference from it is the omitted
    /// retirement.
    func tearDown(reason: PlaybackReason) {
        isPlaybackRequested = false
        cancelActivationWait()
        engine.pause()
    }

    /// Resumes for an interruption-ended/route-reconnected reason.
    /// `PlaybackInterruptionContext` declares this `throws` to match the
    /// source contract this was ported from; nothing here actually throws.
    func play(reason: PlaybackReason) throws {
        resume()
    }

    /// Cancels the engine-event consumer.
    ///
    /// The task holds only a `weak self`, so it never keeps this controller
    /// alive — it just parks on the stream forever once nobody is left to
    /// deliver to, one leaked task per controller ever built. `Task` is
    /// `Sendable`, which is what lets a `@MainActor` class's nonisolated
    /// `deinit` touch it.
    deinit {
        // All three unstructured tasks, not just the stream consumer. Each
        // holds `[weak self]` so none retains the controller, but an
        // uncancelled one outlives it: `refetchTask` runs a manifest request to
        // its full timeout before discovering `self == nil`, and
        // `activationWaitTask` captures the coordinator *strongly* (`guard let
        // audioSession`), so a dead controller keeps an `AudioSessionCoordinator`
        // alive behind a sleeping task. `Task` is `Sendable`, which is what
        // lets a `@MainActor` class's nonisolated `deinit` touch them.
        eventsTask?.cancel()
        refetchTask?.cancel()
        activationWaitTask?.cancel()
    }
}
