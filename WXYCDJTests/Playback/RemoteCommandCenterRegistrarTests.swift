//
//  RemoteCommandCenterRegistrarTests.swift
//  WXYCDJTests
//
//  Unit tests for the issue-#138 lock-screen transport registration: that the
//  `addTarget` handles are retained (so the no-ops can be detached again at
//  issue #145) and that the enabled/disabled flags are set in both directions
//  rather than inherited from MPRemoteCommandCenter's all-enabled defaults.
//  Each test's doc comment states the single-line production mutation it
//  would catch.
//
//  These run against the real `MPRemoteCommandCenter.shared()` — the class is
//  a process singleton with no constructible alternative — but each test
//  registers through its own `RemoteCommandCenterRegistrar` instance and
//  removes only that instance's own targets, so the host app's launch-time
//  registration is left intact.
//
//  `noOpHandler` itself is deliberately NOT unit-tested: invoking it needs an
//  `MPRemoteCommandEvent`, and `-[MPRemoteCommandEvent init]` raises
//  `NSGenericException: MPRemoteCommandEvents cannot be initialized
//  externally`, which terminates the whole test process rather than failing
//  one test (measured, not assumed). Its `.noSuchContent` return is a single
//  source literal; the facts worth guarding here are the retention and the
//  flags, both of which are covered below.
//
//  Created by Jake Bromberg on 08/30/26.
//  Copyright © 2026 WXYC. All rights reserved.
//

import MediaPlayer
import Testing
@testable import WXYCAPI
@testable import WXYCDJ

@MainActor
@Suite(.serialized)
struct RemoteCommandCenterRegistrarTests {
    /// Catches: dropping `addTarget(handler:)`'s return value on the floor —
    /// i.e. reverting the registration line to a bare
    /// `command.addTarget(handler: Self.noOpHandler)`. That token is the only
    /// thing `removeTarget(_:)` accepts and `MPRemoteCommand` has no
    /// remove-all API, so discarding it makes the no-op handler permanently
    /// un-detachable.
    @Test("registering retains one addTarget token per handled command")
    func registrationRetainsEveryTarget() {
        let registrar = RemoteCommandCenterRegistrar()
        defer { registrar.removeNoOpCommands() }

        registrar.registerNoOpCommands()

        #expect(registrar.registeredTargets.count == 5)
    }

    /// Catches: `removeNoOpCommands()` failing to **clear** the ledger — e.g.
    /// dropping its `registeredTargets.removeAll()`, or the whole method.
    ///
    /// It deliberately does **not** claim to catch a dropped
    /// `command.removeTarget(target)`: `MPRemoteCommand` exposes no public
    /// target list and `MPRemoteCommandEvent` cannot be constructed (see this
    /// file's header), so the detach itself is unobservable from a test. That
    /// half is held by review, not by this assertion — deleting only the
    /// `removeTarget` loop leaves this test green while leaving every
    /// `.noSuchContent` no-op permanently attached, which is the defect the
    /// retained tokens exist to prevent.
    @Test("removing clears every retained target")
    func removalClearsEveryTarget() {
        let registrar = RemoteCommandCenterRegistrar()
        registrar.registerNoOpCommands()
        #expect(!registrar.registeredTargets.isEmpty)

        registrar.removeNoOpCommands()

        #expect(registrar.registeredTargets.isEmpty)
    }

    /// Catches: deleting any one of the `command.isEnabled = false` lines in
    /// `unsupportedCommands`' loop. `MPRemoteCommandCenter.shared()` defaults
    /// every command to enabled, so an omitted flag advertises transport the
    /// app has no target for at all — worse than the registered no-ops, which
    /// at least answer.
    @Test("unsupported transport commands are explicitly disabled")
    func unsupportedCommandsAreDisabled() {
        let center = MPRemoteCommandCenter.shared()
        // The complement of the handled five over the WHOLE command centre,
        // not just the six wxyc-ios-64 names: anything absent from both lists
        // stays enabled at the framework default with no target.
        let unsupported: [(name: String, command: MPRemoteCommand)] = [
            ("stop", center.stopCommand),
            ("seekForward", center.seekForwardCommand),
            ("seekBackward", center.seekBackwardCommand),
            ("skipForward", center.skipForwardCommand),
            ("skipBackward", center.skipBackwardCommand),
            ("changePlaybackPosition", center.changePlaybackPositionCommand),
            ("changePlaybackRate", center.changePlaybackRateCommand),
            ("changeRepeatMode", center.changeRepeatModeCommand),
            ("changeShuffleMode", center.changeShuffleModeCommand),
            ("rating", center.ratingCommand),
            ("like", center.likeCommand),
            ("dislike", center.dislikeCommand),
            ("bookmark", center.bookmarkCommand),
            ("enableLanguageOption", center.enableLanguageOptionCommand),
            ("disableLanguageOption", center.disableLanguageOptionCommand),
        ]
        // Start from the framework default (everything enabled) so the
        // assertions below can only pass if registration wrote the flag.
        for entry in unsupported { entry.command.isEnabled = true }
        let registrar = RemoteCommandCenterRegistrar(commandCenter: center)
        defer { registrar.removeNoOpCommands() }

        registrar.registerNoOpCommands()

        for entry in unsupported {
            #expect(entry.command.isEnabled == false, "\(entry.name) should be disabled")
        }
    }

    /// Catches: deleting the `command.isEnabled = true` line in
    /// `handledCommands`' loop, or dropping a command from that list — most
    /// pointedly `togglePlayPauseCommand`, which the source registers and
    /// which is what a headphone single-press sends, so its absence would
    /// leave issue #145's body swap with no toggle path to fill in.
    @Test("handled transport commands are explicitly enabled and each carries a target")
    func handledCommandsAreEnabled() {
        let center = MPRemoteCommandCenter.shared()
        let handled: [(name: String, command: MPRemoteCommand)] = [
            ("play", center.playCommand),
            ("pause", center.pauseCommand),
            ("togglePlayPause", center.togglePlayPauseCommand),
            ("nextTrack", center.nextTrackCommand),
            ("previousTrack", center.previousTrackCommand),
        ]
        // Start from the opposite of the expected value so a missing
        // `isEnabled = true` cannot pass on the framework default.
        for entry in handled { entry.command.isEnabled = false }
        let registrar = RemoteCommandCenterRegistrar(commandCenter: center)
        defer { registrar.removeNoOpCommands() }

        registrar.registerNoOpCommands()

        for entry in handled {
            #expect(entry.command.isEnabled == true, "\(entry.name) should be enabled")
            #expect(
                registrar.registeredTargets.contains { $0.command === entry.command },
                "\(entry.name) should carry a retained no-op target"
            )
        }
    }

    /// Catches: `registerPlaybackCommands(controller:)` dropping its
    /// `removeNoOpCommands()` call -- the standing obligation from issue
    /// #138/#145. Without it, `registeredTargets` (and therefore the
    /// no-op handlers it was retained to let this method detach) would
    /// survive the call, leaving every command carrying both a live
    /// handler and the `.noSuchContent` no-op.
    @Test("wiring real playback commands detaches every retained no-op target first")
    func registeringPlaybackCommandsDetachesNoOpsFirst() async throws {
        let (api, _) = try await SignedInClient.make()
        let controller = PlaybackController(engine: InertPlaybackEngine(), api: api)
        let registrar = RemoteCommandCenterRegistrar()
        registrar.registerNoOpCommands()
        #expect(registrar.registeredTargets.count == 5)

        registrar.registerPlaybackCommands(controller: controller)

        #expect(registrar.registeredTargets.isEmpty, "the no-op tokens must be detached before real handlers are wired")
    }

    /// Catches: `registerPlaybackCommands(controller:)` being called without
    /// a prior `registerNoOpCommands()` -- it must not crash or leave
    /// `unsupportedCommands` enabled just because there was nothing to
    /// detach. `removeNoOpCommands()` on an empty ledger is a documented
    /// no-op.
    @Test("wiring real playback commands with nothing registered yet does not crash")
    func registeringPlaybackCommandsWithNothingToRemoveIsSafe() async throws {
        let (api, _) = try await SignedInClient.make()
        let controller = PlaybackController(engine: InertPlaybackEngine(), api: api)
        let registrar = RemoteCommandCenterRegistrar()

        registrar.registerPlaybackCommands(controller: controller)

        #expect(registrar.registeredTargets.isEmpty)
    }
}
