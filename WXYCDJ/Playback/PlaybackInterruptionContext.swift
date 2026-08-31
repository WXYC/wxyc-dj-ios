//
//  PlaybackInterruptionContext.swift
//  WXYCDJ
//
//  Ported from wxyc-ios-64's
//  Shared/Playback/Sources/PlaybackCore/PlaybackInterruptionContext.swift
//  (c22a3eb). Deviations from the source:
//   - `sessionID` and `playbackDuration` are dropped. Both existed solely to
//     populate the source's `PlaybackStoppedEvent` analytics capture, and
//     WXYC/wxyc-dj-ios#138 strips PlaybackInterruptionRouteHandler's Analytics
//     dependency entirely (this app's analytics contract is stricter --
//     see docs/adr/0007-ios-anonymous-error-reporting.md -- and playback
//     telemetry is WXYC/wxyc-dj-ios#139's scope, not this one's). With no
//     analytics capture left in the handler, nothing else reads either
//     property.
//   - No `@MainActor package` access level: this is an app-target file, not a
//     Swift package boundary, so `protocol` (internal) is the equivalent of
//     the source's `package protocol`.
//   - Nothing conforms to this protocol yet. WXYC/wxyc-dj-ios#144's
//     PlaybackController is the first conformer, exactly as the source's
//     AudioPlayerController/RadioPlayerController conform directly (#804).
//
//  Created by Jake Bromberg on 08/30/26.
//  Copyright © 2026 WXYC. All rights reserved.
//

/// Narrow, module-scoped read/write surface `PlaybackInterruptionRouteHandler`
/// needs from its owning controller.
@MainActor
protocol PlaybackInterruptionContext: AnyObject {
    /// Whether the controller is currently playing.
    var isPlaying: Bool { get }

    /// Whether playback was active immediately before the last route
    /// disconnect. Stays controller-owned rather than handler-owned -- a
    /// future `play()` and stop-teardown path would also need to touch it --
    /// so this is threaded through as a get/set pair rather than the handler
    /// holding its own copy.
    var wasPlayingBeforeRouteDisconnect: Bool { get set }

    /// Tears playback down for the given reason (`.interruptionBegan` / `.routeDisconnected`).
    func tearDown(reason: PlaybackReason)

    /// (Re)starts playback for the given reason (`.resumeAfterInterruption` / `.resumeAfterRouteReconnect`).
    func play(reason: PlaybackReason) throws
}
