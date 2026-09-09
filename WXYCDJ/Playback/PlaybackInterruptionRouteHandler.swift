//
//  PlaybackInterruptionRouteHandler.swift
//  WXYCDJ
//
//  Ported from wxyc-ios-64's
//  Shared/Playback/Sources/PlaybackCore/PlaybackInterruptionRouteHandler.swift
//  (c22a3eb, 194 lines). That file owns the AVAudioSession
//  interruption/route-change notification subscription, the case switch over
//  each notification's type/reason, and a shared analytics capture, shared
//  between two controllers (AudioPlayerController and RadioPlayerController)
//  that duplicated the switch verbatim. Deviations from the source, all
//  driven by this app having neither of those controllers yet:
//   - **Analytics stripped entirely** (WXYC/wxyc-dj-ios#138's explicit
//     scope): no `AnalyticsService` dependency, no `PlaybackStoppedEvent`
//     capture. This app's analytics contract is stricter than the listener
//     app's (docs/adr/0007-ios-anonymous-error-reporting.md), and playback
//     telemetry is WXYC/wxyc-dj-ios#139's scope, not this one's.
//   - **The six per-controller hook closures are dropped**
//     (`onInterruptionReceived`, `onInterruptionWillStopForPlayback`,
//     `onInterruptionBeganHandled`, `onInterruptionEndedWithoutResume`,
//     `onRouteChangeReceived`, `onRouteChangeRestartFallback`). The source
//     added them in wxyc-ios-64#756 so one handler could serve two divergent
//     controllers; this app has exactly one playback surface, so there is no
//     second controller to diverge for. WXYC/wxyc-dj-ios#144's
//     PlaybackController conforms to `PlaybackInterruptionContext` directly
//     and needs no hook seam.
//   - **The source's generic `MainActorNotificationMessage` /
//     `addMainActorObserver` messaging framework (from wxyc-ios-64's `Core`
//     package, which this app does not depend on) is collapsed into direct
//     `NotificationCenter` observation** of `AVAudioSession
//     .interruptionNotification` / `.routeChangeNotification`, decoding
//     `userInfo` inline via the same keys the source's `InterruptionMessage`
//     / `RouteChangeMessage` used. Functionally identical; kept self-contained
//     since this is the only notification-observation code in this app. The
//     one part of that framework's *shape* that is kept deliberately is
//     **where** the decode happens: `makeMessage(_ notification: sending
//     Notification) -> Self?` runs in the nonisolated observer block and only
//     the resulting `Sendable` message crosses into
//     `MainActor.assumeIsolated`. The observer blocks below do the same --
//     they read `userInfo` into plain value types (`InterruptionType`,
//     `InterruptionOptions`, `RouteChangeReason`) and hop with those, never
//     with the `Notification` itself. That is load-bearing, not tidiness;
//     see the next bullet.
//   - Logging hooks are replaced with `os.Logger` calls, matching this
//     module's existing convention (see `AudioSessionCoordinator.swift`).
//   - **The source's `Core` package declares `extension Notification:
//     @unchecked @retroactive Sendable`; this port deliberately does not, and
//     the decode placement above is what makes that possible.** An earlier
//     draft of this file hopped with the raw `Notification` and needed the
//     conformance to compile (`error: sending 'notification' risks causing
//     data races` -- region isolation sees a task-isolated `Notification`
//     captured by a main-actor-isolated closure). Restating the conformance
//     is the wrong way to buy that: Foundation ships `@available(*,
//     unavailable) extension Notification: Sendable`, an explicit "this type
//     is NOT Sendable" marker, so the declaration earns `warning: conformance
//     of 'Notification' to protocol 'Sendable' was already stated in the
//     type's module 'Foundation'` and installs a duplicate conformance record
//     for a Foundation type -- the hazard class `CLAUDE.md` documents for
//     `String: @retroactive CodingKey`. And the blast radius differs between
//     the two repos: in wxyc-ios-64 it is confined to the small `Core`
//     module, whereas here it would blanket the whole `WXYCDJ` module plus
//     `WXYCDJTests` via `@testable import`, so a future capture site sending
//     a `userInfo` holding a non-`Sendable` class reference across an
//     isolation boundary would compile silently. Narrowing what crosses to
//     three `RawRepresentable` value types gets the same compile with none of
//     that, and is what the source's `makeMessage` split does too.
//
//  Behaviours kept from the source: `.began` -> pause, `.ended` +
//  `.shouldResume` -> resume, `.oldDeviceUnavailable` -> pause, and
//  `cancelPendingInterruptionResume()`. Its doc comment below is *adapted*
//  rather than copied verbatim -- the source names `PlaybackStopTeardown` as
//  the caller, which does not exist here -- but the reason-bounded rule it
//  states is unchanged and is an obligation on WXYC/wxyc-dj-ios#144/#145; see
//  that comment.
//
//  Created by Jake Bromberg on 08/30/26.
//  Copyright © 2026 WXYC. All rights reserved.
//

import AVFoundation
import Foundation
import os

/// Subscribes to `AVAudioSession.interruptionNotification` /
/// `.routeChangeNotification` and runs the interruption/route-change state
/// machine against an injected `PlaybackInterruptionContext`.
///
/// Holds `context` weakly: this handler is owned by the controller it reads
/// from, so a strong reference here would cycle.
@MainActor
final class PlaybackInterruptionRouteHandler {
    private let notificationCenter: NotificationCenter
    private weak var context: (any PlaybackInterruptionContext)?
    private let log = Logger(subsystem: "org.wxyc.dj", category: "playback")

    /// Whether playback was active immediately before the current
    /// interruption began, so `.ended` knows whether a resume is warranted.
    /// Scoped entirely to this handler, and reset to `false` at the end of
    /// every `.ended` case.
    private var wasPlayingBeforeInterruption = false

    private var interruptionObservation: (any NSObjectProtocol)?
    private var routeChangeObservation: (any NSObjectProtocol)?

    init(notificationCenter: NotificationCenter, context: any PlaybackInterruptionContext) {
        self.notificationCenter = notificationCenter
        self.context = context

        // Both blocks decode `userInfo` *before* the main-actor hop, so only
        // `Sendable` value types cross the isolation boundary and no
        // `Notification` is ever sent -- the split the source performs in
        // `InterruptionMessage`/`RouteChangeMessage.makeMessage(_:)`, and the
        // reason this file needs no retroactive `Notification: Sendable`
        // conformance (file header).
        interruptionObservation = notificationCenter.addObserver(
            forName: AVAudioSession.interruptionNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let typeRaw = notification.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
                  let type = AVAudioSession.InterruptionType(rawValue: typeRaw) else {
                return
            }
            let optionsRaw = notification.userInfo?[AVAudioSessionInterruptionOptionKey] as? UInt ?? 0
            let options = AVAudioSession.InterruptionOptions(rawValue: optionsRaw)
            MainActor.assumeIsolated {
                self?.handleInterruption(type: type, options: options)
            }
        }
        routeChangeObservation = notificationCenter.addObserver(
            forName: AVAudioSession.routeChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let reasonRaw = notification.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt,
                  let reason = AVAudioSession.RouteChangeReason(rawValue: reasonRaw) else {
                return
            }
            MainActor.assumeIsolated {
                self?.handleRouteChange(reason: reason)
            }
        }
    }

    @MainActor
    deinit {
        if let interruptionObservation { notificationCenter.removeObserver(interruptionObservation) }
        if let routeChangeObservation { notificationCenter.removeObserver(routeChangeObservation) }
    }

    /// Retires a pending post-interruption resume, so an interruption that
    /// has begun but not yet ended will not restart playback when it does.
    ///
    /// Without this the flag is unreachable from outside -- it is set on
    /// `.began` and cleared only at the end of `.ended` -- so a DJ who paused
    /// from the Lock Screen during a phone call would have playback restart
    /// on them the moment the call ended.
    ///
    /// **The production caller is
    /// ``PlaybackController/retireAutoResumeState(reason:)``**, as of
    /// WXYC/wxyc-dj-ios#145 — the obligation this comment used to record as
    /// outstanding is discharged. It mirrors the source's
    /// `PlaybackStopTeardown.retireAutoResumeState(…)` (`c22a3eb`) and applies
    /// the same **reason-bounded rule**: a stop that is *itself* an
    /// auto-resume-bearing stop preserves the pending resume, and any other
    /// stop retires it. This field's exemption is **both**
    /// `.interruptionBegan` (its own teardown) and `.routeDisconnected` (a
    /// disconnect landing mid-call must not cancel the call's pending resume)
    /// — deliberately *not* the same exemption set as the controller's
    /// `wasPlayingBeforeRouteDisconnect`, which is why that method is
    /// reason-bounded rather than a single shared flag.
    ///
    /// Whatever calls this, the rule holds or the Lock-Screen-pause-during-a-
    /// call defect above returns with the flag once again unreachable.
    func cancelPendingInterruptionResume() {
        wasPlayingBeforeInterruption = false
    }

    private func handleInterruption(
        type: AVAudioSession.InterruptionType,
        options: AVAudioSession.InterruptionOptions
    ) {
        switch type {
        case .began:
            wasPlayingBeforeInterruption = context?.isPlaying ?? false
            if context?.isPlaying ?? false {
                log.info("Interruption began while playing; pausing")
                context?.tearDown(reason: .interruptionBegan)
            }

        case .ended:
            if options.contains(.shouldResume) && wasPlayingBeforeInterruption {
                log.info("Interruption ended with shouldResume; resuming")
                try? context?.play(reason: .resumeAfterInterruption)
            }
            wasPlayingBeforeInterruption = false

        @unknown default:
            break
        }
    }

    private func handleRouteChange(reason: AVAudioSession.RouteChangeReason) {
        switch reason {
        case .oldDeviceUnavailable:
            // Headphones unplugged - stop playback per Apple HIG.
            let wasPlaying = context?.isPlaying ?? false
            context?.wasPlayingBeforeRouteDisconnect = wasPlaying
            if wasPlaying {
                log.info("Old device unavailable while playing; pausing")
                context?.tearDown(reason: .routeDisconnected)
            }

        case .newDeviceAvailable:
            // Device reconnected (e.g. headphones reinserted) - resume only
            // if we were playing before disconnect.
            if context?.wasPlayingBeforeRouteDisconnect ?? false {
                log.info("New device available; resuming")
                try? context?.play(reason: .resumeAfterRouteReconnect)
            }

        default:
            break
        }
    }
}
