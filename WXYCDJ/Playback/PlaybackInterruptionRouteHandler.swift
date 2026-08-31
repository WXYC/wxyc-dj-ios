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
//     since this is the only notification-observation code in this app.
//   - Logging hooks are replaced with `os.Logger` calls, matching this
//     module's existing convention (see `AudioSessionCoordinator.swift`).
//
//  Kept unchanged from the source: `.began` -> pause, `.ended` +
//  `.shouldResume` -> resume, `.oldDeviceUnavailable` -> pause, and
//  `cancelPendingInterruptionResume()` -- see its own doc comment below for
//  why it must stay.
//
//  Created by Jake Bromberg on 08/30/26.
//  Copyright © 2026 WXYC. All rights reserved.
//

import AVFoundation
import Foundation
import os

/// `Notification`'s `userInfo` is `[AnyHashable: Any]`, which the compiler
/// cannot prove `Sendable`, so passing a posted `Notification` from the
/// `@Sendable` observer block below into `MainActor.assumeIsolated` needs an
/// explicit opt-in. A posted `Notification` is effectively immutable and,
/// once posted, only ever read here on the main queue we observe on. Matches
/// wxyc-ios-64's identical workaround in its `Core` package
/// (`MainActorMessage.swift`).
extension Notification: @unchecked @retroactive Sendable {}

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

        interruptionObservation = notificationCenter.addObserver(
            forName: AVAudioSession.interruptionNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            MainActor.assumeIsolated {
                self?.handleInterruption(notification)
            }
        }
        routeChangeObservation = notificationCenter.addObserver(
            forName: AVAudioSession.routeChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            MainActor.assumeIsolated {
                self?.handleRouteChange(notification)
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
    func cancelPendingInterruptionResume() {
        wasPlayingBeforeInterruption = false
    }

    private func handleInterruption(_ notification: Notification) {
        guard let typeRaw = notification.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
              let type = AVAudioSession.InterruptionType(rawValue: typeRaw) else {
            return
        }
        let optionsRaw = notification.userInfo?[AVAudioSessionInterruptionOptionKey] as? UInt ?? 0
        let options = AVAudioSession.InterruptionOptions(rawValue: optionsRaw)

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

    private func handleRouteChange(_ notification: Notification) {
        guard let reasonRaw = notification.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt,
              let reason = AVAudioSession.RouteChangeReason(rawValue: reasonRaw) else {
            return
        }

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
