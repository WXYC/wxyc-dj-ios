//
//  PlaybackFailureCopy.swift
//  WXYCDJ
//
//  User-facing copy for a terminal PlaybackFailure / PlaybackEngineFailure
//  (issue #151). Two pure, host-testable total switches -- no `default:` on
//  either -- so a future enum case is a compile-time decision rather than a
//  message quietly falling through. Shared by AlbumDetailView's Play section
//  (the synchronous start() refusal) and MainView's mini-player (the
//  persistent surface for a mid-playback failure -- see ADR 0008 Amendment
//  6), so the two surfaces can never drift to different wording for the same
//  case. Not a member of either view: neither one "owns" this mapping, and
//  hanging it off the enums themselves keeps both call sites reading from
//  the same source rather than each switching over PlaybackFailure on its
//  own.
//
//  Created by Jake Bromberg on 08/31/26.
//  Copyright © 2026 WXYC. All rights reserved.
//

import Foundation

/// Maps a terminal playback failure to copy a DJ can read and act on. Holds
/// no state, and every string here is fixed -- never anything derived from
/// the manifest's presigned URL, which is a bearer credential until
/// `expires_at` and must never reach the screen (or a log, or telemetry).
enum PlaybackFailureCopy {
    /// A total switch over all six `PlaybackFailure` cases, matching the
    /// no-`default:` convention `AlbumDetailView.classifyPlaybackManifestFailure`
    /// and `AuthError.caseName` already use: a future case is a compile
    /// error here, not a message that silently falls through to something
    /// generic.
    ///
    /// `.emptyManifest` and `.noPlayableRendition` deliberately read
    /// differently -- an unbound album is a coverage gap ("nothing here
    /// yet"), a codec gap is a capability limit ("this app can't play what's
    /// here") -- preserving the distinction issue #144 introduced the enum
    /// to carry.
    nonisolated static func message(for failure: PlaybackFailure) -> String {
        switch failure {
        case .manifestExpiring:
            "This album's playback link expired. Reopen it to keep listening."
        case .emptyManifest:
            "Nothing is available to play for this album yet."
        case .noPlayableRendition:
            "This app can't play any of the audio formats available for this album."
        case .engine(let engineFailure):
            message(for: engineFailure)
        case .refetchFailed:
            "Couldn't refresh playback for this album. Try again."
        case .audioSessionUnavailable:
            "Couldn't play this album."
        }
    }

    /// The engine's own closed classification (ADR 0008 Amendment 3), folded
    /// into one generic message on purpose: none of the four is something a
    /// DJ can act on differently from the others, which is exactly the
    /// "generic couldn't-play-this for the engine and session cases"
    /// treatment the issue's acceptance criteria calls for. Still a total
    /// switch with no `default:` -- a fifth `PlaybackEngineFailure` case is a
    /// compile error here until this function is updated, never a silent
    /// fallthrough to the same string by omission.
    nonisolated static func message(for engineFailure: PlaybackEngineFailure) -> String {
        switch engineFailure {
        case .mediaForbidden, .mediaFailed, .decodeFailed, .unknown:
            "Couldn't play this album."
        }
    }
}
