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
//  Owns three observers per queued player: a KVO watch on
//  `player.timeControlStatus` (-> `.timeControl`), a KVO watch on the current
//  item's `status` (-> `.failed`, via `classifyFailure(errorStatusCode:)`),
//  and `AVPlayerItem.didPlayToEndTimeNotification` scoped to the current item
//  (-> `.itemEnded` -- `AVQueuePlayer` advances its own queue on this
//  automatically, matching the seam's contract that the engine advances
//  itself). `.firstFrame` (the cue→first-frame interval issue #139 reports)
//  comes from a periodic time observer: the first callback where playback
//  time has moved past zero while the player is actually `.playing`, once per
//  cued item.
//
//  This adapter, like `AlbumDetailView`'s private async wiring, is the
//  documented-but-untested carve-out (ADR 0008 Amendment 3): a SwiftUI
//  view's private methods and an AVFoundation adapter's callback wiring both
//  have no test harness in this repo. What *is* tested is
//  `classifyFailure(errorStatusCode:)` -- the pure `Int? -> PlaybackEngineFailure`
//  mapping, independent of how the `Int?` was obtained from
//  `AVPlayerItem.errorLog()`.
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
/// identical reasoning): every stored property here is touched only from the
/// callers `PlaybackController` (a `@MainActor` class) makes and from
/// AVFoundation's own callbacks, which this type registers exclusively on
/// the main queue (`addPeriodicTimeObserver(forInterval:queue:using:)`'s
/// `queue: .main`, `NotificationCenter.addObserver(_:queue: .main, ...)`) or
/// which AVFoundation itself already dispatches to the main thread in
/// practice for player-level KVO. There is deliberately no internal locking
/// -- the soundness condition is "never touched off the main queue", not
/// "safe under arbitrary concurrent access".
final class AVQueuePlayerEngine: PlaybackEngine, @unchecked Sendable {
    private let player: AVQueuePlayer
    private let notificationCenter: NotificationCenter

    let events: AsyncStream<PlaybackEngineEvent>
    private let continuation: AsyncStream<PlaybackEngineEvent>.Continuation

    private var timeControlObservation: NSKeyValueObservation?
    private var currentItemObservation: NSKeyValueObservation?
    private var itemStatusObservation: NSKeyValueObservation?
    private var itemEndObserver: (any NSObjectProtocol)?
    private var periodicTimeObserverToken: Any?

    /// Whether `.firstFrame` has already fired for whatever item is
    /// currently cued at index 0 of the player's queue. Reset every time
    /// `currentItem` changes, so each newly-cued track earns its own
    /// first-frame timing.
    private var firstFrameFiredForCurrentItem = false

    init(notificationCenter: NotificationCenter = .default) {
        let player = AVQueuePlayer()
        self.player = player
        self.notificationCenter = notificationCenter
        let (stream, continuation) = AsyncStream<PlaybackEngineEvent>.makeStream()
        self.events = stream
        self.continuation = continuation

        timeControlObservation = player.observe(\.timeControlStatus, options: [.new]) { [continuation] player, _ in
            continuation.yield(.timeControl(isPlaying: player.timeControlStatus == .playing))
        }
        periodicTimeObserverToken = player.addPeriodicTimeObserver(
            forInterval: CMTime(value: 1, timescale: 20),
            queue: .main
        ) { [weak self] time in
            self?.handlePeriodicTime(time)
        }
        currentItemObservation = player.observe(\.currentItem, options: [.new]) { [weak self] player, _ in
            self?.attachItemObservers(to: player.currentItem)
        }
    }

    deinit {
        if let itemEndObserver {
            notificationCenter.removeObserver(itemEndObserver)
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

    private func attachItemObservers(to item: AVPlayerItem?) {
        itemStatusObservation = nil
        if let itemEndObserver {
            notificationCenter.removeObserver(itemEndObserver)
        }
        itemEndObserver = nil
        firstFrameFiredForCurrentItem = false
        guard let item else { return }

        itemStatusObservation = item.observe(\.status, options: [.new]) { [weak self] item, _ in
            guard item.status == .failed else { return }
            self?.reportFailure(for: item)
        }
        itemEndObserver = notificationCenter.addObserver(
            forName: AVPlayerItem.didPlayToEndTimeNotification,
            object: item,
            queue: .main
        ) { [continuation] _ in
            continuation.yield(.itemEnded)
        }
    }

    private func reportFailure(for item: AVPlayerItem) {
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
