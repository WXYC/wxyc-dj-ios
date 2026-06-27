//
//  OfflineSessionPolicy.swift
//  WXYCAPI
//
//  Pure decision for the offline cold-launch restore (issue #57). When the
//  JWT exchange fails transiently (network / 5xx / undecodable body) on a
//  cold launch, AuthService consults this policy to decide whether a returning
//  DJ stays signed in on the cached identity within a bounded grace window, or
//  is dropped to the login screen. The window is anchored on the last
//  confirmed server contact (`lastValidatedAt`), never the JWT `exp`.
//
//  Created by Jake on 6/26/26.
//  Copyright © 2026 WXYC. All rights reserved.
//

import Foundation

public enum OfflineSessionPolicy {
    /// How long a returning DJ may stay signed in offline, measured from the
    /// last confirmed server contact. 30 days.
    public static let defaultWindow: TimeInterval = 30 * 24 * 60 * 60

    public enum Decision: Equatable, Sendable {
        case signedIn(JWTPayload)
        case signedOut
    }

    /// Decide the offline cold-launch restore outcome.
    ///
    /// Returns `.signedIn(payload)` iff a stored session exists **and** a cached
    /// payload exists **and** `lastValidatedAt` is non-nil **and** the elapsed
    /// time since `lastValidatedAt` is **finite** and strictly less than `window`.
    /// Otherwise `.signedOut`.
    ///
    /// The window is **exclusive** at exactly `window` seconds: `elapsed < window`
    /// is in, `elapsed == window` is out. A `lastValidatedAt` in the *finite*
    /// future (mild clock skew) reads as in-window (negative elapsed), the
    /// lenient choice. A **non-finite** anchor (a corrupted/tampered value that
    /// parsed to ±∞) fails closed to `.signedOut` — without that guard a `+∞`
    /// anchor would give `elapsed == -∞ < window` and grant grace forever.
    public static func decide(
        hasStoredSession: Bool,
        cachedPayload: JWTPayload?,
        lastValidatedAt: Date?,
        now: Date,
        window: TimeInterval = defaultWindow
    ) -> Decision {
        guard hasStoredSession,
              let payload = cachedPayload,
              let anchor = lastValidatedAt
        else {
            return .signedOut
        }
        // Require a finite elapsed before the `< window` test. A corrupted or
        // tampered anchor that parses to a non-finite `Date`
        // (`Date(timeIntervalSince1970: .infinity)`) yields `elapsed == -.infinity`,
        // which is `< window` and would pin the DJ to signed-in forever —
        // defeating the bounded window. A `nan` elapsed already fails the
        // comparison, but guard it explicitly so the fail-closed posture is
        // independent of `<`'s NaN behavior.
        let elapsed = now.timeIntervalSince(anchor)
        guard elapsed.isFinite, elapsed < window else {
            return .signedOut
        }
        return .signedIn(payload)
    }
}
