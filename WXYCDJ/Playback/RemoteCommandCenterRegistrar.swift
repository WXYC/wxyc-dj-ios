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

    /// The transport commands this app does **not** service, disabled
    /// explicitly because every `MPRemoteCommandCenter` command defaults to
    /// enabled. Advertising one with no target is worse than a no-op.
    private var unsupportedCommands: [MPRemoteCommand] {
        [
            commandCenter.stopCommand,
            commandCenter.seekForwardCommand,
            commandCenter.seekBackwardCommand,
            commandCenter.skipForwardCommand,
            commandCenter.skipBackwardCommand,
            commandCenter.changePlaybackPositionCommand,
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
}
