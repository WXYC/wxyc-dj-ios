//
//  PlaybackEngine.swift
//  WXYCDJ
//
//  The narrow seam PlaybackController drives audio through (issue #144), and
//  the three value types that cross it: the queue element, the event stream's
//  vocabulary, and the closed failure enum that vocabulary carries. Nothing
//  here imports AVFoundation -- the single conformer that does is
//  AVQueuePlayerEngine (issue #145), which is what keeps every decision the
//  controller makes host-testable against SpyPlaybackEngine.
//
//  Created by Jake Bromberg on 08/30/26.
//  Copyright © 2026 WXYC. All rights reserved.
//

import Foundation
import WXYCAPI

// MARK: - PlaybackItem

/// One cued track: a presigned URL plus everything a lock screen, a
/// mini-player, or a telemetry event needs to describe what is playing.
///
/// **`albumTitle` and `artistName` do not come from the manifest.**
/// `DigitalArchivePlaybackManifest` is `{library_id, expires_at, tracks[]}`
/// and carries neither, so the detail screen's own state (`AlbumInfo`, or the
/// `AlbumSearchResult` fallback behind it) supplies them at
/// ``PlaybackController/start(manifest:albumTitle:artistName:)`` and they ride
/// the queue from there -- otherwise issue #138's `NowPlayingInfoCenterManager`
/// has nothing to put on the lock screen and the mini-player has nothing to
/// label.
///
/// ``provenance`` is per-track rather than per-item-batch for the reason the
/// schema gives: the `digital_asset` unique key is
/// `(library_id, provenance, disc_number)`, so one album can hold several bound
/// assets and a manifest merges them.
struct PlaybackItem: Sendable, Equatable, Identifiable, CustomStringConvertible {
    /// `digital_asset_file.id` -- stable across manifest refetches, which is
    /// what lets a post-403 refetch resume on the same track rather than the
    /// same array index.
    let fileId: Int
    /// The presigned GET. **A bearer credential until the manifest expires:**
    /// never `os_log` it, never put it in an `NSError` `userInfo`, never hand
    /// it to telemetry. ``description`` deliberately omits it so an
    /// interpolated `"\(item)"` in a future log line can't leak it either.
    let url: URL
    let codec: DigitalArchivePlaybackRendition.Codec
    let title: String
    let albumTitle: String
    let artistName: String
    let discNumber: Int?
    let trackNumber: Int?
    let durationSecs: Double?
    let provenance: DigitalArchivePlaybackTrack.Provenance

    var id: Int { fileId }

    /// Everything except the URL. The omission is the point -- see ``url``.
    var description: String {
        "PlaybackItem(fileId: \(fileId), title: \(title), album: \(albumTitle), artist: \(artistName), codec: \(codec.rawValue))"
    }
}

// MARK: - Events

/// Why a cued item stopped being playable.
///
/// **Closed, and deliberately not an untyped `Error`.** `AVPlayer` never
/// surfaces an HTTP status through `AVPlayerItem.error`: a failed media load
/// arrives as `AVFoundationErrorDomain -11800` wrapping an opaque
/// `NSOSStatusErrorDomain` code, and the status only exists inside
/// `AVPlayerItem.errorLog()`'s `AVPlayerItemErrorLogEvent.errorStatusCode`. A
/// controller handed an `any Error` therefore has *nothing* it can match on to
/// mean "403" -- while a spy can be made to emit anything, which is how an
/// untyped seam produces a green suite over an app that cannot do what the
/// suite claims. `AVQueuePlayerEngine` (issue #145) owns the
/// `errorStatusCode` → case mapping as its one piece of documented-but-untested
/// wiring. Issue #139's `ArchivePlaybackFailureReason` already assumes these
/// cases exist and switches over them with no `default:`.
enum PlaybackEngineFailure: Equatable, Sendable {
    /// The presigned URL was rejected -- expired, revoked, or signed for a
    /// different object. The one case ``PlaybackController`` can act on: it
    /// refetches the manifest once.
    case mediaForbidden
    /// Reachable but unplayable -- any other server or transport refusal.
    case mediaFailed
    /// The bytes arrived and the decoder rejected them.
    case decodeFailed
    /// Anything the engine could not classify.
    case unknown
}

/// What the engine tells the controller. Four cases, matching ADR 0008's
/// deliberately narrow seam.
enum PlaybackEngineEvent: Equatable, Sendable {
    /// The engine's own belief about whether audio is flowing. Distinct from
    /// ``PlaybackController/isPlaybackRequested`` on purpose -- see that
    /// property.
    case timeControl(isPlaying: Bool)
    /// The current item played to its end. The engine advances its own queue;
    /// this only tells the controller to move its cursor.
    case itemEnded
    case failed(PlaybackEngineFailure)
    /// The first sample of the most recently cued item actually rendered.
    /// Closes the cue→first-frame interval issue #139 reports.
    case firstFrame
}

// MARK: - The seam

/// Loads and transports a queue of ``PlaybackItem``s.
///
/// In the style of `RequestSession` / `PathProvider` / `ThumbnailProviding`: a
/// small `Sendable` protocol whose real conformer is one file that imports the
/// framework, and whose test conformer records calls. Commands are synchronous
/// and fire-and-forget; everything the caller learns back arrives on ``events``.
protocol PlaybackEngine: AnyObject, Sendable {
    /// The engine's event feed. **One stream per engine instance**, not a
    /// fresh one per call: an `AsyncStream` supports a single iterator, so a
    /// conformer must vend the same value every time.
    var events: AsyncStream<PlaybackEngineEvent> { get }

    /// Replaces the queue with `items`, cued at `items.first`.
    func load(_ items: [PlaybackItem])
    func play()
    func pause()
    /// Skips to the next item. Not called on ``PlaybackEngineEvent/itemEnded``
    /// -- the engine advances itself there.
    func advance()
    func seek(to time: TimeInterval)
}

// MARK: - Placeholder conformer

/// The conformer the composition root wires until issue #145 lands
/// `AVQueuePlayerEngine`.
///
/// Accepts every command and emits no events, so the controller sits in its
/// "requested, not yet playing" state forever. That is not a state a DJ can
/// reach today: this PR ships no transport UI, and nothing calls
/// ``PlaybackController/start(manifest:albumTitle:artistName:)``. Its only job
/// is to let ``AppDependencies`` own a real controller now, so issue #145 is a
/// one-line substitution rather than a composition-root change.
final class InertPlaybackEngine: PlaybackEngine {
    let events: AsyncStream<PlaybackEngineEvent>

    init() {
        // Finished immediately: the controller's consumer task then exits
        // rather than parking forever on a stream nothing will ever feed.
        let (stream, continuation) = AsyncStream<PlaybackEngineEvent>.makeStream()
        continuation.finish()
        self.events = stream
    }

    func load(_ items: [PlaybackItem]) {}
    func play() {}
    func pause() {}
    func advance() {}
    func seek(to time: TimeInterval) {}
}
