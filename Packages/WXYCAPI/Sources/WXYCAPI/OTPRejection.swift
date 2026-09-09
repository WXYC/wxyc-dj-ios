//
//  OTPRejection.swift
//  WXYCAPI
//
//  Turns better-auth's one-time-code refusal codes into copy that names the
//  DJ's actual next move (issue #100).
//
//  Created by Jake on 08/18/26.
//  Copyright © 2026 WXYC. All rights reserved.
//

import Foundation

/// The refusals `POST /auth/sign-in/email-otp` can answer with, and what to tell
/// the DJ about each.
///
/// better-auth's own messages ("Invalid OTP", "OTP expired", "Too many
/// attempts") are accurate but describe the *server's* finding rather than the
/// DJ's next action, and two of the three call for genuinely different actions:
/// a wrong code should be retyped, an expired one must be re-requested, and a
/// lockout can only be cleared by requesting a fresh code. Rendering all three
/// as the server's terse phrasing would leave the DJ guessing which situation
/// they are in.
///
/// The wire `code` is matched as a plain `String` rather than decoded into this
/// enum, so a code shipped server-side ahead of the app degrades to the server's
/// own message instead of throwing — the same forward-compatible posture
/// ``SignInIdentifier`` and ``ArtworkFailureClassification`` take.
enum OTPRejection: String {
    /// `400` — the code doesn't match. Also what an unknown *account* gets, since
    /// `disableSignUp: true` makes the server refuse to distinguish the two.
    case invalidOTP = "INVALID_OTP"
    /// `400` — past the 5-minute `expiresIn` window.
    case expiredOTP = "OTP_EXPIRED"
    /// `403`, not `400` — `atomicVerifyOTP` raises this one with
    /// `APIError.from("FORBIDDEN", …)` while the other two are `"BAD_REQUEST"`.
    /// Both statuses land in the same refusal arm, so nothing branches on the
    /// difference, but tests that stub it must use 403.
    case tooManyAttempts = "TOO_MANY_ATTEMPTS"

    /// Copy naming the recovery this refusal actually calls for.
    ///
    /// Deliberately **unpunctuated at the end**: these reach the DJ through
    /// ``AuthError/rejected(message:)``, whose renderer appends a period
    /// unconditionally and carries no doubling guard, on the stated grounds that
    /// better-auth's own messages arrive unpunctuated. Ending these where the
    /// server's own messages end keeps that contract true rather than widening it
    /// for one caller.
    var copy: String {
        switch self {
        case .invalidOTP: "That code isn't right. Check it and try again"
        case .expiredOTP: "That code has expired. Request a new one"
        case .tooManyAttempts: "Too many incorrect attempts. Request a new code"
        }
    }

    /// The `rejectionCopy` hook `AuthService.establishSession` calls on a 400/403
    /// from the OTP route: friendlier wording when the code is one of ours,
    /// otherwise the server's own message untouched.
    static func copy(for code: String?, fallback: String?) -> String? {
        code.flatMap { OTPRejection(rawValue: $0) }?.copy ?? fallback
    }
}
