//
//  AVQueuePlayerEngine.swift
//  WXYCDJ
//
//  The one real PlaybackEngine conformer (issue #145) -- and, deliberately,
//  **the only file in this app that imports AVFoundation for actual
//  playback.** AudioSessionCoordinator/AudioSessionProtocol and
//  PlaybackInterruptionRouteHandler import it too, but only for the
//  AVAudioSession session/notification surface, never a player.
//
//  AVQueuePlayer plus one AVPlayerItem per queued track: the framework
//  pre-buffers the next item on its own. Every presigned URL goes straight
//  into `AVURLAsset(url:)` -- **no custom headers, no
//  `AVAssetResourceLoaderDelegate`.** AVFoundation loads media out-of-process
//  in `mediaserverd`, which is exactly why the manifest contract presigns
//  URLs instead of expecting a bearer token; intercepting the load would
//  break that boundary and put the credential back in-process. No downloads
//  either -- no `AVAssetDownloadTask`, no on-disk copies; transient `AVPlayer`
//  buffering is the ceiling (ADR 0008).
//
//  **The presigned URL is a bearer credential until the manifest's
//  `expires_at`.** This file never `os_log`s a `PlaybackItem`'s `url`, never
//  places one in an `NSError` `userInfo` it constructs, and never hands one
//  to telemetry -- `PlaybackItem.description` already omits it so an
//  interpolated `"\(item)"` can't leak it either (see PlaybackEngine.swift).
//
//  `CookielessSession` does not cover this file's media loads: like
//  `AsyncImage` (issue #105), `AVURLAsset` performs its own fetch outside the
//  `RequestSession` seam entirely. Presigned S3-style GETs set no cookies, so
//  nothing fills a jar there is no session wrapping in the first place -- a
//  fact worth noting here rather than working around, since there is nothing
//  to work around.
//
//  Player-level observers: a KVO watch on `player.timeControlStatus` (->
//  `.timeControl`), a KVO watch on `player.currentItem` (which re-points the
//  per-item observers), and a periodic time observer feeding `.firstFrame`
//  (the cue→first-frame interval issue #139 reports) on the first callback
//  where playback time has moved past zero while the player is actually
//  `.playing`, once per cued item.
//
//  Per-item observers, re-pointed on every `currentItem` change: a KVO watch
//  on `status` registered with `[.initial, .new]`,
//  `AVPlayerItem.didPlayToEndTimeNotification` (-> `.itemEnded` --
//  `AVQueuePlayer` advances its own queue on this automatically, matching the
//  seam's contract that the engine advances itself), and
//  `AVPlayerItem.failedToPlayToEndTimeNotification` (-> `.failed`). The two
//  failure signals are both required and neither subsumes the other: an item
//  AVQueuePlayer pre-buffered can be `.failed` *before* it becomes current
//  (which `.initial` catches and `.new` alone cannot), while a stream dying
//  mid-track leaves `status` at `.readyToPlay` and posts only the
//  failed-to-play-to-end notification. Both route through
//  `classifyFailure(errorStatusCode:)` behind a per-item dedup guard.
//
//  Most of this adapter, like `AlbumDetailView`'s private async wiring, is the
//  documented-but-untested carve-out (ADR 0008 Amendment 3) -- there is no
//  harness here for driving a real AVPlayerItem through a *network* failure.
//  Two things escape it and are covered: `classifyFailure(errorStatusCode:)`,
//  the pure `Int? -> PlaybackEngineFailure` mapping; and the per-item failure
//  observation, which needs no network at all (a nonexistent local file
//  reaches `.failed` in well under a second, and the mid-playback signal is a
//  post on the injected `NotificationCenter`).
//
//  Created by Jake Bromberg on 08/31/26.
//  Copyright © 2026 WXYC. All rights reserved.
//

import AVFoundation
import Foundation
import os

private let playbackEngineLog = Logger(subsystem: "org.wxyc.dj", category: "playback")

/// `@unchecked Sendable`, matching this codebase's other AVFoundation/Core
/// Spotlight adapters (`RealSearchableIndex`'s doc comment states the
/// identical reasoning). The soundness condition is **"every stored property
/// is written only on the main queue"**, not "safe under arbitrary concurrent
/// access", and this type makes that true by construction rather than by
/// assumption:
///
/// - `PlaybackController` is `@MainActor`, so every command call arrives there.
/// - The periodic time observer and both `NotificationCenter` observers are
///   registered with `queue: .main`, so their callbacks are delivered there.
/// - **KVO delivery is a different matter, and is not guaranteed.**
///   `AVPlayerItem.status` and `AVPlayer.timeControlStatus` are
///   `NS_SWIFT_NONISOLATED` in the SDK, and AVFoundation has never documented
///   a delivery queue for player-level KVO — an earlier revision of this
///   comment asserted it "already dispatches to the main thread in practice",
///   which is an observation, not a contract. So the two KVO handlers below
///   assume nothing: each captures what it needs as a value and hops to
///   `DispatchQueue.main.async` before touching any stored property. The one
///   exception is `continuation.yield(_:)`, which `AsyncStream.Continuation`
///   documents as safe to call from any thread, so the `timeControlStatus`
///   observer yields inline and stores nothing.
final class AVQueuePlayerEngine: PlaybackEngine, @unchecked Sendable {
    private let player: AVQueuePlayer
    private let notificationCenter: NotificationCenter

    let events: AsyncStream<PlaybackEngineEvent>
    private let continuation: AsyncStream<PlaybackEngineEvent>.Continuation

    private var timeControlObservation: NSKeyValueObservation?
    private var currentItemObservation: NSKeyValueObservation?
    private var itemStatusObservation: NSKeyValueObservation?
    private var itemEndObserver: (any NSObjectProtocol)?
    private var itemFailureObserver: (any NSObjectProtocol)?
    private var periodicTimeObserverToken: Any?

    /// Whether `.firstFrame` has already fired for whatever item is
    /// currently cued at index 0 of the player's queue. Reset every time
    /// `currentItem` changes, so each newly-cued track earns its own
    /// first-frame timing.
    private var firstFrameFiredForCurrentItem = false

    /// Whether a `.failed` has already been yielded for the current item.
    ///
    /// Three signals converge on one item — the attach-time status check, the
    /// `status` KVO, and `failedToPlayToEndTimeNotification` — and two of them
    /// routinely fire for the same failure. A second `.failed` is not merely
    /// noise: `PlaybackController` spends its one-shot manifest refetch on the
    /// first and surfaces the second as a terminal `.engine(...)`, tearing the
    /// queue down for a signature problem the refetch had already fixed. Reset
    /// in ``attachItemObservers(to:)`` so the *next* item re-arms.
    private var didReportFailureForCurrentItem = false

    init(notificationCenter: NotificationCenter = .default) {
        let player = AVQueuePlayer()
        self.player = player
        self.notificationCenter = notificationCenter
        let (stream, continuation) = AsyncStream<PlaybackEngineEvent>.makeStream()
        self.events = stream
        self.continuation = continuation

        // Yields inline and stores nothing, so it needs no main-queue hop:
        // `AsyncStream.Continuation.yield(_:)` is documented as callable from
        // any thread. `change.newValue` rather than a re-read of the player,
        // so the event reports the transition that fired it.
        timeControlObservation = player.observe(\.timeControlStatus, options: [.new]) { [continuation] _, change in
            guard let status = change.newValue else { return }
            continuation.yield(.timeControl(isPlaying: status == .playing))
        }
        periodicTimeObserverToken = player.addPeriodicTimeObserver(
            forInterval: CMTime(value: 1, timescale: 20),
            queue: .main
        ) { [weak self] time in
            self?.handlePeriodicTime(time)
        }
        // Hops to the main queue before touching stored state: KVO delivery is
        // not documented to be main-queue (see the type's doc comment), and
        // `attachItemObservers(to:)` writes five stored properties that
        // `handlePeriodicTime` reads on `.main`. `change.newValue` (an
        // `AVPlayerItem??`, flattened) captures the item at notification time
        // rather than re-reading `player.currentItem` after the hop, which
        // could already have moved on. `DispatchQueue.main` is serial, so two
        // rapid item changes still apply in order.
        currentItemObservation = player.observe(\.currentItem, options: [.new]) { [weak self] _, change in
            let item = change.newValue ?? nil
            DispatchQueue.main.async { self?.attachItemObservers(to: item) }
        }
    }

    deinit {
        for observer in [itemEndObserver, itemFailureObserver].compactMap({ $0 }) {
            notificationCenter.removeObserver(observer)
        }
        if let periodicTimeObserverToken {
            player.removeTimeObserver(periodicTimeObserverToken)
        }
        continuation.finish()
    }

    // MARK: PlaybackEngine

    func load(_ items: [PlaybackItem]) {
        player.pause()
        player.removeAllItems()
        for item in items {
            let playerItem = AVPlayerItem(asset: AVURLAsset(url: item.url))
            player.insert(playerItem, after: player.items().last)
        }
    }

    func play() { player.play() }
    func pause() { player.pause() }
    /// `AVQueuePlayer` advances itself on `.itemEnded`; this is the "tell the
    /// engine to advance" arm `PlaybackController.advance()` calls.
    func advance() { player.advanceToNextItem() }
    func seek(to time: TimeInterval) {
        player.seek(to: CMTime(seconds: time, preferredTimescale: 1000))
    }

    // MARK: - Per-item observation

    /// Points the three per-item signals at `item`, detaching whatever the
    /// previous item had.
    ///
    /// **Not `private`, and the reason is a real test rather than convenience:**
    /// the pre-buffered-failure case below cannot be reached through `load()`,
    /// because an `AVPlayerItem` handed to `AVQueuePlayer` becomes `currentItem`
    /// (and is observed) long before its asset load can fail. `AVQueuePlayerEngineTests`
    /// therefore drives an item to `.failed` on its own and calls this directly.
    ///
    /// **The status observation asks for `.initial` as well as `.new`, and that
    /// is the whole point.** `AVQueuePlayer` prepares the *next* item while the
    /// current one plays, so a later track's `AVPlayerItem` can reach `.failed`
    /// **before** it ever becomes `currentItem`. A `[.new]`-only observer
    /// registered on an item already at its terminal status never fires at all:
    /// nothing is yielded, `PlaybackController` never sees `.failed`, the
    /// one-shot 403 refetch never runs, and — because `AVQueuePlayer` only
    /// auto-advances on `didPlayToEndTime` — playback simply stalls with the
    /// transport still reading "playing".
    ///
    /// The third signal, `failedToPlayToEndTimeNotification`, covers the case
    /// neither status path can: a failure *after* the item started playing (a
    /// presigned URL expiring mid-track), where `status` stays `.readyToPlay`
    /// and only this notification is posted.
    func attachItemObservers(to item: AVPlayerItem?) {
        itemStatusObservation = nil
        for observer in [itemEndObserver, itemFailureObserver].compactMap({ $0 }) {
            notificationCenter.removeObserver(observer)
        }
        itemEndObserver = nil
        itemFailureObserver = nil
        firstFrameFiredForCurrentItem = false
        // Re-armed per item, so the dedup guard below scopes to this item
        // rather than latching for the engine's lifetime and swallowing the
        // *next* dead URL in the queue.
        didReportFailureForCurrentItem = false
        guard let item else { return }

        itemStatusObservation = item.observe(\.status, options: [.initial, .new]) { [weak self] item, _ in
            guard item.status == .failed else { return }
            // Hop before touching `didReportFailureForCurrentItem`: KVO
            // delivery is not documented to be main-queue. The `.initial`
            // callback fires synchronously from `observe(...)` on whatever
            // queue called `attachItemObservers`, so this defers it by one
            // turn — harmless, since nothing here is ordered against the
            // remaining registrations below.
            DispatchQueue.main.async { self?.reportFailure(for: item) }
        }
        itemEndObserver = notificationCenter.addObserver(
            forName: AVPlayerItem.didPlayToEndTimeNotification,
            object: item,
            queue: .main
        ) { [continuation] _ in
            continuation.yield(.itemEnded)
        }
        itemFailureObserver = notificationCenter.addObserver(
            forName: AVPlayerItem.failedToPlayToEndTimeNotification,
            object: item,
            queue: .main
        ) { [weak self] _ in
            self?.reportFailure(for: item)
        }
    }

    private func reportFailure(for item: AVPlayerItem) {
        // At most one `.failed` per item. Two of the three signals routinely
        // fire for the same failure, and a duplicate is not just noise --
        // `PlaybackController` spends its one-shot refetch on the first and
        // treats the second as terminal. See `didReportFailureForCurrentItem`.
        guard !didReportFailureForCurrentItem else { return }
        didReportFailureForCurrentItem = true
        // `errorStatusCode` is a plain `Int`, not optional -- `0` is what an
        // error-log event reports when no HTTP-level status was ever
        // determined, which this normalizes to `nil` so
        // `classifyFailure(errorStatusCode:)` reads it as "no status", not
        // as a (nonexistent) HTTP status `0`.
        let rawStatusCode = item.errorLog()?.events.last?.errorStatusCode
        let statusCode = (rawStatusCode == 0) ? nil : rawStatusCode
        playbackEngineLog.error("Playback item failed; errorStatusCode=\(statusCode.map(String.init) ?? "nil", privacy: .public)")
        continuation.yield(.failed(Self.classifyFailure(errorStatusCode: statusCode)))
    }

    private func handlePeriodicTime(_ time: CMTime) {
        guard !firstFrameFiredForCurrentItem, time.seconds > 0, player.timeControlStatus == .playing else { return }
        firstFrameFiredForCurrentItem = true
        continuation.yield(.firstFrame)
    }

    // MARK: - The one pure, testable decision

    /// `AVPlayerItem.error` never surfaces an HTTP status -- a failed media
    /// load arrives as `AVFoundationErrorDomain -11800` wrapping an opaque
    /// `OSStatus`, and the status only exists inside
    /// `AVPlayerItem.errorLog()`'s last event's `errorStatusCode` (ADR 0008
    /// Amendment 3). This is that mapping, pulled out as a pure function so
    /// it is testable independent of how the `Int?` was obtained.
    ///
    /// `403` is the one status `PlaybackController` can act on (its one-shot
    /// manifest refetch): `.mediaForbidden`. Any other status reached the
    /// server and was refused for some other reason: `.mediaFailed`. `nil`
    /// (no HTTP-level error-log event at all) means the bytes arrived and
    /// the decoder rejected them: `.decodeFailed`. `.unknown` is not
    /// reachable from this mapping -- it exists on `PlaybackEngineFailure`
    /// for a case this engine cannot classify at all, which "an error
    /// occurred" with or without a status code is not.
    nonisolated static func classifyFailure(errorStatusCode: Int?) -> PlaybackEngineFailure {
        switch errorStatusCode {
        case .some(403): .mediaForbidden
        case .some: .mediaFailed
        case .none: .decodeFailed
        }
    }
}
