//
//  PlaybackReason.swift
//  WXYCDJ
//
//  A minimal stand-in for wxyc-ios-64's PlaybackCore/PlaybackReason.swift,
//  which is a 30-plus-case RawRepresentable struct because it is shared
//  across that app's many playback entry points (remote commands, Siri
//  intents, CarPlay, widgets, ...) and used to tag analytics events. This app
//  has none of that yet and its own PlaybackInterruptionRouteHandler port
//  strips the Analytics dependency entirely (WXYC/wxyc-dj-ios#138), so only
//  the four cases that handler actually assigns are declared here. A plain
//  enum, not the source's extensible struct, since every case so far lives in
//  this one module -- WXYC/wxyc-dj-ios#144's PlaybackController can add more
//  cases directly.
//
//  Created by Jake Bromberg on 08/30/26.
//  Copyright © 2026 WXYC. All rights reserved.
//

/// Why a `PlaybackInterruptionContext` conformer was asked to pause or resume.
enum PlaybackReason {
    case interruptionBegan
    case resumeAfterInterruption
    case routeDisconnected
    case resumeAfterRouteReconnect
}
