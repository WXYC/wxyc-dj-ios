//
//  RemoteCommandCenterRegistrar.swift
//  WXYCDJ
//
//  Not a port -- wxyc-ios-64 wires its MPRemoteCommandCenter commands
//  straight to a real player, and this app has neither a player nor a
//  controller yet (WXYC/wxyc-dj-ios#144/#145). WXYC/wxyc-dj-ios#138's body
//  originally asked for play/pause/next/previous "enabled," which the wave-2
//  retrospective on that issue found unsatisfiable: there is nothing here for
//  a handler to call, and wiring a target protocol in this PR would smuggle
//  in #144's seam ahead of its own review. Instead this registers the four
//  commands with explicit no-op handlers, each returning `.noSuchContent` --
//  the MPRemoteCommandHandlerStatus for "a legitimate command with nothing to
//  act on." WXYC/wxyc-dj-ios#145 is the ticket that replaces `noOpHandler`
//  with real playback control once a PlaybackController exists to receive it.
//
//  Created by Jake Bromberg on 08/30/26.
//  Copyright © 2026 WXYC. All rights reserved.
//

import MediaPlayer

@MainActor
enum RemoteCommandCenterRegistrar {
    /// Registers play/pause/next-track/previous-track on `commandCenter`,
    /// each with `noOpHandler` as its sole target.
    static func registerNoOpCommands(on commandCenter: MPRemoteCommandCenter = .shared()) {
        for command in [
            commandCenter.playCommand,
            commandCenter.pauseCommand,
            commandCenter.nextTrackCommand,
            commandCenter.previousTrackCommand,
        ] {
            command.addTarget(handler: noOpHandler)
        }
    }

    /// Acknowledges the command without acting on it. `.noSuchContent` is the
    /// literal answer: nothing exists yet to play, pause, or skip to.
    static func noOpHandler(_ event: MPRemoteCommandEvent) -> MPRemoteCommandHandlerStatus {
        .noSuchContent
    }
}
