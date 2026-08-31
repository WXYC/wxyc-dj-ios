//
//  RemoteCommandCenterRegistrar.swift
//  WXYCDJ
//
//  Not a file-level port -- wxyc-ios-64 wires its MPRemoteCommandCenter
//  commands straight to a real player, and this app has neither a player nor a
//  controller yet (WXYC/wxyc-dj-ios#144/#145). WXYC/wxyc-dj-ios#138's body
//  originally asked for play/pause/next/previous "enabled," which the wave-2
//  retrospective on that issue found unsatisfiable: there is nothing here for
//  a handler to call, and wiring a target protocol in this PR would smuggle in
//  #144's seam ahead of its own review. Instead this registers the transport
//  commands with explicit no-op handlers, each returning `.noSuchContent` --
//  the MPRemoteCommandHandlerStatus for "a legitimate command with nothing to
//  act on." WXYC/wxyc-dj-ios#145 is the ticket that replaces `noOpHandler`
//  with real playback control once a PlaybackController exists to receive it.
//
//  It does mirror the *shape* of the source's
//  `AudioPlayerController.setUpRemoteCommandCenter()` (`c22a3eb`, ~line 1606)
//  and `removeRemoteCommandTargets()` (~line 1702) in the three respects that
//  make #145 a body swap rather than a fresh design. Deviations from that
//  source, and from #138's body, are noted here:
//   - **Every `addTarget(handler:)` return value is retained** in
//     `registeredTargets`, exactly as the source appends each to its
//     `commandTargets` array. `MPRemoteCommand` has no remove-all API and
//     `removeTarget(_:)` accepts nothing else, so a discarded token is a
//     permanently un-detachable handler. That matters concretely at #145:
//     its natural shape is a `PlaybackController` registering real handlers
//     while `AppDelegate` still performs this registration at launch, which
//     would leave `playCommand` carrying two targets -- one of them
//     unconditionally answering `.noSuchContent` for a command the app can by
//     then service -- with no way to detach it short of relaunching. Hence
//     `removeNoOpCommands()`, and hence this being an instance rather than
//     the source's controller-owned array (there is no controller yet to own
//     one).
//   - **The enabled/disabled flags are set explicitly, both ways.**
//     `MPRemoteCommandCenter.shared()` defaults *every* command to
//     `isEnabled == true`, so saying nothing advertises `stopCommand`,
//     `seekForward`/`seekBackward`, `skipForward`/`skipBackward` and
//     `changePlaybackPosition` to the system with no target at all -- worse
//     than a no-op, which at least answers. The curated set below is:
//     **enabled** = exactly the commands registered here; **disabled** =
//     every other transport command the source names. The source disables the
//     same six (`stop`, `next`, `previous`, `seekForward`, `seekBackward`,
//     plus `skipForward`/`skipBackward`/`changePlaybackPosition` on its
//     non-time-shiftable branch); this app enables `next`/`previous` because,
//     unlike the listener app's single live stream, it has a real queue
//     (#138's body). `changePlaybackPosition` stays disabled here even though
//     archive tracks are scrubbable -- #145 enables it when it wires a seek.
//   - **`togglePlayPauseCommand` is registered, making five commands rather
//     than #138's stated four.** The source registers it, and it is what a
//     headphone single-press and most Bluetooth head units send; leaving it
//     out would give #145's body swap no toggle path to fill in. A superset
//     of the issue's acceptance criterion, deliberately.
//
//  Created by Jake Bromberg on 08/30/26.
//  Copyright © 2026 WXYC. All rights reserved.
//

import MediaPlayer

/// Registers the lock-screen / Control Center transport commands, and keeps
/// the handles needed to unregister them again.
@MainActor
final class RemoteCommandCenterRegistrar {
    private let commandCenter: MPRemoteCommandCenter

    /// The `(command, target)` pairs handed back by `addTarget(handler:)`.
    ///
    /// Retained because `removeTarget(_:)` accepts nothing else and
    /// `MPRemoteCommand` has no remove-all API -- see the file header. The
    /// token is typed `Any` (the source's `commandTargets` array is `[Any]`
    /// for the same reason), so it is stored as-is and handed straight back.
    /// Not `private` so a test can assert the tokens are actually kept;
    /// nothing outside this type reads it.
    private(set) var registeredTargets: [(command: MPRemoteCommand, target: Any)] = []

    init(commandCenter: MPRemoteCommandCenter = .shared()) {
        self.commandCenter = commandCenter
    }

    /// The commands this app registers a handler for. Each is enabled, and
    /// each carries `noOpHandler` until WXYC/wxyc-dj-ios#145 swaps the bodies.
    private var handledCommands: [MPRemoteCommand] {
        [
            commandCenter.playCommand,
            commandCenter.pauseCommand,
            commandCenter.togglePlayPauseCommand,
            commandCenter.nextTrackCommand,
            commandCenter.previousTrackCommand,
        ]
    }

    /// Every command this app does **not** service, disabled explicitly
    /// because each one defaults to enabled and advertising a command with no
    /// target is worse than a no-op -- the Now Playing and CarPlay surfaces
    /// render an affordance that does nothing when tapped.
    ///
    /// This is deliberately the **complement of ``handledCommands`` over the
    /// whole of `MPRemoteCommandCenter`**, not the subset wxyc-ios-64 happened
    /// to name. The source disables only what its own two controllers could
    /// surface; scoping to that list here left `changeRepeatModeCommand`,
    /// `changeShuffleModeCommand`, `changePlaybackRateCommand`, the four
    /// feedback commands and the two language-option commands enabled and
    /// untargeted -- and shuffle/repeat are exactly the affordances a system
    /// surface offers an app that, as the `nextTrackCommand` note above says,
    /// has a real queue. The two lists together must stay exhaustive: a
    /// command in neither is enabled by default with no handler.
    private var unsupportedCommands: [MPRemoteCommand] {
        [
            commandCenter.stopCommand,
            commandCenter.seekForwardCommand,
            commandCenter.seekBackwardCommand,
            commandCenter.skipForwardCommand,
            commandCenter.skipBackwardCommand,
            commandCenter.changePlaybackPositionCommand,
            commandCenter.changePlaybackRateCommand,
            commandCenter.changeRepeatModeCommand,
            commandCenter.changeShuffleModeCommand,
            commandCenter.ratingCommand,
            commandCenter.likeCommand,
            commandCenter.dislikeCommand,
            commandCenter.bookmarkCommand,
            commandCenter.enableLanguageOptionCommand,
            commandCenter.disableLanguageOptionCommand,
        ]
    }

    /// Enables and registers `handledCommands`, disables
    /// `unsupportedCommands`, and retains every returned target so
    /// ``removeNoOpCommands()`` can detach them.
    func registerNoOpCommands() {
        for command in handledCommands {
            command.isEnabled = true
            registeredTargets.append((command, command.addTarget(handler: Self.noOpHandler)))
        }
        for command in unsupportedCommands {
            command.isEnabled = false
        }
    }

    /// Detaches every target this registrar added, leaving the enabled flags
    /// alone. WXYC/wxyc-dj-ios#145 calls this before wiring real handlers, so
    /// a command cannot end up carrying both a live handler and a `.noSuchContent`
    /// no-op.
    func removeNoOpCommands() {
        for (command, target) in registeredTargets {
            command.removeTarget(target)
        }
        registeredTargets.removeAll()
    }

    /// Acknowledges the command without acting on it. `.noSuchContent` is the
    /// literal answer: nothing exists yet to play, pause, or skip to.
    static func noOpHandler(_ event: MPRemoteCommandEvent) -> MPRemoteCommandHandlerStatus {
        .noSuchContent
    }

    /// Replaces every no-op handler with a real one driving `controller`
    /// (issue #145). **Calls ``removeNoOpCommands()`` first** -- the standing
    /// obligation this type's header names: without it, `playCommand` would
    /// carry both a live handler and the `.noSuchContent` no-op that
    /// unconditionally refuses, with no way to detach the no-op short of
    /// relaunching (`MPRemoteCommand` has no remove-all API).
    ///
    /// The five real handlers are not retained in ``registeredTargets`` --
    /// nothing in this app's lifetime needs to detach them again, unlike the
    /// no-ops they replace, which existed only to be swapped out once a
    /// controller was available.
    ///
    /// `previousTrackCommand` has no backward-navigation counterpart on
    /// `PlaybackController` (the seam only ever moves the queue forward via
    /// ``PlaybackController/advance()``), so its handler restarts the
    /// current track -- the same "previous means restart, not skip back"
    /// convention most transport surfaces fall back to when there is nothing
    /// earlier to skip to.
    ///
    /// Each handler hops to the main actor with `Task { @MainActor in … }` and
    /// returns `.success` synchronously, exactly as this app's reference
    /// implementation does (`wxyc-ios-64`'s
    /// `AudioPlayerController.setUpRemoteCommandCenter()`, the file this type
    /// mirrors).
    ///
    /// **Deliberately not `MainActor.assumeIsolated`.** `assumeIsolated`
    /// *traps* when the assumption is false, and the queue
    /// `MPRemoteCommandCenter` invokes a handler on is **not documented** —
    /// not in `MPRemoteCommand.h`, not in the online reference. An earlier
    /// revision of this comment claimed Apple documents it as the main queue;
    /// that claim could not be substantiated and has been removed rather than
    /// replaced with a different guess. Since the assumption is unverified, one
    /// delivery from anywhere else — a Bluetooth or CarPlay head unit, a
    /// launch-into-background headphone press, a future OS change — would be a
    /// hard crash on a lock-screen button press. The `Task` form costs nothing
    /// here: all five calls are fire-and-forget and none of them informs the
    /// returned status, so nothing is waiting on the hop.
    ///
    /// That is also why these differ in shape from
    /// `PlaybackInterruptionRouteHandler`'s notification callbacks, which
    /// *can* use `MainActor.assumeIsolated`: those observers are registered
    /// with an explicit `queue: .main`, so their delivery queue is a fact this
    /// app establishes rather than one it hopes for.
    func registerPlaybackCommands(controller: PlaybackController) {
        removeNoOpCommands()
        commandCenter.playCommand.addTarget { _ in
            Task { @MainActor in controller.resume() }
            return .success
        }
        commandCenter.pauseCommand.addTarget { _ in
            Task { @MainActor in controller.pause() }
            return .success
        }
        commandCenter.togglePlayPauseCommand.addTarget { _ in
            Task { @MainActor in controller.togglePlayPause() }
            return .success
        }
        commandCenter.nextTrackCommand.addTarget { _ in
            Task { @MainActor in controller.advance() }
            return .success
        }
        commandCenter.previousTrackCommand.addTarget { _ in
            Task { @MainActor in controller.seek(to: 0) }
            return .success
        }
    }
}
