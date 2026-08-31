//
//  NowPlayingInfoCenterManager.swift
//  WXYCDJ
//
//  Ported from wxyc-ios-64's WXYC/iOS/NowPlayingInfoCenterManager.swift
//  (c22a3eb, 149 lines). Deviations from the source:
//   - **`handleNowPlayingItem(_:)`'s `Playcut`/`NowPlayingItem` mapping, the
//     `PlatformImage` artwork plumbing, and the `boundsSize` init parameter
//     are dropped; the metadata write itself is not.** The digital-archive
//     playback manifest carries no album title and no artist name
//     (WXYC/wxyc-shared#422), so `setNowPlayingItem(title:artistName:albumTitle:)`
//     takes three plain strings instead of a `Playcut`: `PlaybackController`
//     supplies them off the queued `PlaybackItem`, which carried them from the
//     detail screen's own state (ADR 0008 Amendment 4). Artwork stays dropped
//     -- nothing in the playback path holds a cover. `clear()` is the
//     queue-ending counterpart, added with the same wiring.
//   - **`clear()` has no source counterpart.** The listener app plays one
//     endless stream and never takes itself off the Now Playing card; this app
//     stops, fails, and runs off the end of a queue, and each of those must
//     leave the Lock Screen showing nothing rather than a track that is no
//     longer cued.
//   - **`updatePlaybackPosition`'s parameters change meaning.** The source's
//     `secondsBehindLive`/`maxLookback` model a time-shifted *live radio*
//     stream; this app plays fixed-length archive tracks, so the equivalent
//     scrub-bar update is expressed as a plain `elapsed`/`duration` pair.
//   - **Two live-radio assumptions the source could safely make are dropped,
//     because this app is archive-only (ADR 0008, WXYC/wxyc-dj-ios#138) and
//     its tracks are fixed-length and pausable.** Both would be wrong here:
//     - The source's `updatePlaybackPosition` writes
//       `MPNowPlayingInfoPropertyPlaybackRate = 1.0` unconditionally, which
//       is true for it because a live stream is playing whenever a position
//       is written at all. Here a DJ can pause: `setPlaybackState(isPlaying:
//       false)` writes rate `0.0`, and any position flush or in-flight tick
//       from WXYC/wxyc-dj-ios#145's periodic time observer would then
//       overwrite it back to `1.0` while `infoCenter.playbackState` stayed
//       `.paused` -- a Lock Screen scrub bar advancing against a paused
//       player. So `setPlaybackState` is the **sole author of the playback
//       rate**, mirrored in `lastKnownIsPlaying`, and a position update
//       restates that mirror rather than asserting `1.0`.
//     - The source's `clearPlaybackPosition` writes
//       `MPNowPlayingInfoPropertyIsLiveStream = true` ("reset to live-stream
//       mode"). Nothing this app plays is a live stream, so it removes the
//       key instead of asserting something false -- and it was asserted by
//       the only method that can clear a position.
//   - The `Dictionary.update(with:)` helper is dropped along with the
//     metadata method it existed only to support.
//   - `@MainActor` isolation and the local-mirror discipline below (never
//     read `nowPlayingInfo` back) are unchanged from the source.
//
//  Created by Jake Bromberg on 08/30/26.
//  Copyright © 2026 WXYC. All rights reserved.
//

import Foundation
import MediaPlayer

/// Abstracts `MPNowPlayingInfoCenter` for testability.
@MainActor
protocol NowPlayingInfoCenterProtocol {
    var nowPlayingInfo: [String: Any]? { get set }
    var playbackState: MPNowPlayingPlaybackState { get set }
}

extension MPNowPlayingInfoCenter: NowPlayingInfoCenterProtocol {}

/// Manages the system's Now Playing info center, updating playback state and
/// position. This class is a simple processor -- callers are responsible for
/// observing playback and calling the handler methods.
@MainActor
final class NowPlayingInfoCenterManager {
    private var infoCenter: NowPlayingInfoCenterProtocol

    /// Local mirror of the dictionary this manager last wrote to `infoCenter`.
    ///
    /// Reading `MPNowPlayingInfoCenter.nowPlayingInfo` is a synchronous
    /// cross-process (XPC) round-trip to `mediaserverd` that can block the
    /// main thread for seconds under contention -- the cause of the source
    /// app's IOS-3P AppHang. Because this manager is the sole writer of the
    /// app's Now Playing info, mutating this cache and writing it back is
    /// equivalent to the read-modify-write the getter used to perform,
    /// without ever blocking the main thread on the getter. Do not
    /// "simplify" this into a read-modify-write against the live getter.
    private var cachedInfo: [String: Any]?

    /// The playback rate this manager last published, as a boolean.
    ///
    /// `setPlaybackState(isPlaying:)` is the sole author of
    /// `MPNowPlayingInfoPropertyPlaybackRate`; this mirrors its last answer so
    /// `updatePlaybackPosition` can restate it instead of asserting `1.0` the
    /// way the live-radio source did. Starts `false` so a position written
    /// before playback has ever been declared reads as paused -- conservative
    /// (a frozen scrub bar that the next `setPlaybackState` corrects) rather
    /// than the reverse, which is the defect this exists to prevent.
    private var lastKnownIsPlaying = false

    /// **`infoCenter` takes no default, deliberately.** The only value it could
    /// default to is the process-wide `MPNowPlayingInfoCenter.default()`, which
    /// inverts this repo's rule that a defaulted dependency is the *inert* one
    /// -- the same argument `AudioSessionCoordinator.init(session:)` makes about
    /// `AVAudioSession.sharedInstance()`. `AppDependencies.init()` names the
    /// shared centre at the one production call site; every other path (both
    /// test-facing `AppDependencies` initializers included) leaves
    /// `PlaybackController`'s `nowPlaying` `nil` and writes nothing at all.
    init(infoCenter: NowPlayingInfoCenterProtocol) {
        self.infoCenter = infoCenter
    }

    /// Write `info` to both the local cache and the system info center in one
    /// place, so the two never diverge and the getter is never consulted.
    private func commit(_ info: [String: Any]) {
        cachedInfo = info
        infoCenter.nowPlayingInfo = info
    }

    /// Seed a mutable copy from the cache, apply `body`, and commit the
    /// result in a single info-center write. Centralizes the read-modify-write
    /// the getter used to perform so every mutation stays one XPC round trip
    /// on the main thread.
    private func mutate(_ body: (inout [String: Any]) -> Void) {
        var info = cachedInfo ?? [:]
        body(&info)
        commit(info)
    }

    // MARK: - Public API

    /// Publish the cued track's metadata to the Lock Screen / Control Centre
    /// card.
    ///
    /// The source's `handleNowPlayingItem(_:)` mapped a `Playcut` (plus
    /// artwork) onto the same three `MPMediaItem` keys; this takes them as
    /// plain strings because the digital-archive manifest carries none of them
    /// -- `albumTitle`/`artistName` ride the queue from the detail screen's own
    /// state (ADR 0008 Amendment 4) and `title` is the track's. Artwork is not
    /// published: nothing in the playback path holds a cover, and the header's
    /// `AsyncImage` load is a `URLCache` fetch in a different layer entirely.
    ///
    /// Goes through ``mutate(_:)`` rather than committing a fresh dictionary,
    /// so a track change preserves the playback rate ``setPlaybackState(isPlaying:)``
    /// is the sole author of.
    func setNowPlayingItem(title: String, artistName: String, albumTitle: String) {
        mutate { info in
            info[MPMediaItemPropertyTitle] = title
            info[MPMediaItemPropertyArtist] = artistName
            info[MPMediaItemPropertyAlbumTitle] = albumTitle
        }
    }

    /// Take the app off the Now Playing card entirely: no metadata, no
    /// position, and a `.stopped` playback state.
    ///
    /// The queue-ending counterpart to ``setNowPlayingItem(title:artistName:albumTitle:)``,
    /// called when playback stops, fails, or runs off the end. Clears the local
    /// mirror as well as the centre — a mirror left populated would seed the
    /// *next* album's first write with the dead one's title — and resets
    /// ``lastKnownIsPlaying``, so a later position write can't publish a
    /// playing rate for an album nobody started.
    func clear() {
        lastKnownIsPlaying = false
        cachedInfo = nil
        infoCenter.nowPlayingInfo = nil
        infoCenter.playbackState = .stopped
    }

    /// Reflect the current playback state in MPNowPlayingInfoCenter.
    ///
    /// The sole *source* of the value written to
    /// `MPNowPlayingInfoPropertyPlaybackRate`, via `lastKnownIsPlaying`.
    /// `updatePlaybackPosition` writes that key too, but only ever restates
    /// this mirror -- it never derives a rate of its own. Nothing else may
    /// decide what the rate is.
    func setPlaybackState(isPlaying: Bool) {
        lastKnownIsPlaying = isPlaying
        mutate { $0[MPNowPlayingInfoPropertyPlaybackRate] = isPlaying ? 1.0 : 0.0 }
        infoCenter.playbackState = isPlaying ? .playing : .paused
    }

    /// Update the playback position for the Lock Screen scrub bar.
    ///
    /// Setting `isLiveStream` to false enables the scrub bar in Control Center
    /// and Lock Screen. The rate written is the one `setPlaybackState` last
    /// published, **never an unconditional `1.0`**: these are fixed-length
    /// pausable tracks, so a position flush arriving after a pause must not
    /// resurrect a playing rate under a `.paused` `playbackState` (see the
    /// file header).
    func updatePlaybackPosition(elapsed: TimeInterval, duration: TimeInterval) {
        mutate { info in
            info[MPMediaItemPropertyPlaybackDuration] = duration
            info[MPNowPlayingInfoPropertyElapsedPlaybackTime] = elapsed
            info[MPNowPlayingInfoPropertyPlaybackRate] = lastKnownIsPlaying ? 1.0 : 0.0
            info[MPNowPlayingInfoPropertyIsLiveStream] = false
        }
    }

    /// Clear the scrub-bar position (duration, elapsed, and the live-stream
    /// declaration alike).
    ///
    /// The source reset `isLiveStream` to `true` here; this app plays no live
    /// stream, so the key is **removed** rather than asserted false-ly (file
    /// header). Mirrors the source's optional-chained semantics otherwise: if
    /// nothing has been set yet, there is no position to clear, so this is a
    /// no-op.
    func clearPlaybackPosition() {
        guard var info = cachedInfo else { return }
        info.removeValue(forKey: MPNowPlayingInfoPropertyIsLiveStream)
        info.removeValue(forKey: MPMediaItemPropertyPlaybackDuration)
        info.removeValue(forKey: MPNowPlayingInfoPropertyElapsedPlaybackTime)
        commit(info)
    }
}
