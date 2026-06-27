//
//  OfflineSessionPolicyTests.swift
//  WXYCAPITests
//
//  Exhaustive table tests for the pure offline cold-launch restore policy:
//  the 30-day grace window's boundary (exclusive at exactly `window`), and
//  every fail-closed input (missing payload / anchor / stored session). Also
//  pins that a within-window decision passes the cached payload through intact
//  (diacritic- and role-bearing, from canonical WXYC data).
//
//  Created by Jake on 6/26/26.
//  Copyright © 2026 WXYC. All rights reserved.
//

import Foundation
import Testing
@testable import WXYCAPI

@Suite("OfflineSessionPolicy")
struct OfflineSessionPolicyTests {
    private static let now = Date(timeIntervalSince1970: 1_900_000_000)
    private static let window = OfflineSessionPolicy.defaultWindow

    /// A role- and diacritic-bearing payload built from canonical-pool data
    /// (Nilüfer Yanya), exercising the Unicode path through the decision.
    private static func payload(exp: TimeInterval = 600) -> JWTPayload {
        JWTPayload(
            sub: "Nilüfer",
            email: "nilufer@wxyc.org",
            role: "dj",
            exp: now.addingTimeInterval(exp)
        )
    }

    @Test func withinWindowSignsInWithCachedPayload() {
        let payload = Self.payload()
        let decision = OfflineSessionPolicy.decide(
            hasStoredSession: true,
            cachedPayload: payload,
            lastValidatedAt: Self.now.addingTimeInterval(-(Self.window - 1)),
            now: Self.now,
            window: Self.window
        )
        #expect(decision == .signedIn(payload))
    }

    @Test func exactlyAtWindowSignsOut() {
        // Boundary is exclusive: elapsed == window is out.
        let decision = OfflineSessionPolicy.decide(
            hasStoredSession: true,
            cachedPayload: Self.payload(),
            lastValidatedAt: Self.now.addingTimeInterval(-Self.window),
            now: Self.now,
            window: Self.window
        )
        #expect(decision == .signedOut)
    }

    @Test func beyondWindowSignsOut() {
        let decision = OfflineSessionPolicy.decide(
            hasStoredSession: true,
            cachedPayload: Self.payload(),
            lastValidatedAt: Self.now.addingTimeInterval(-(Self.window + 1)),
            now: Self.now,
            window: Self.window
        )
        #expect(decision == .signedOut)
    }

    @Test func missingPayloadSignsOut() {
        let decision = OfflineSessionPolicy.decide(
            hasStoredSession: true,
            cachedPayload: nil,
            lastValidatedAt: Self.now.addingTimeInterval(-60),
            now: Self.now,
            window: Self.window
        )
        #expect(decision == .signedOut)
    }

    @Test func missingLastValidatedAtSignsOut() {
        let decision = OfflineSessionPolicy.decide(
            hasStoredSession: true,
            cachedPayload: Self.payload(),
            lastValidatedAt: nil,
            now: Self.now,
            window: Self.window
        )
        #expect(decision == .signedOut)
    }

    @Test func noStoredSessionSignsOut() {
        let decision = OfflineSessionPolicy.decide(
            hasStoredSession: false,
            cachedPayload: Self.payload(),
            lastValidatedAt: Self.now.addingTimeInterval(-60),
            now: Self.now,
            window: Self.window
        )
        #expect(decision == .signedOut)
    }

    @Test func futureAnchorReadsAsInWindow() {
        // Documented leniency: a `lastValidatedAt` in the future (clock skew,
        // negative elapsed) reads as in-window. Pins the behavior the doc
        // comment promises so a later "harden against skew" can't silently
        // flip it to a sign-out.
        let decision = OfflineSessionPolicy.decide(
            hasStoredSession: true,
            cachedPayload: Self.payload(),
            lastValidatedAt: Self.now.addingTimeInterval(60),
            now: Self.now,
            window: Self.window
        )
        #expect(decision == .signedIn(Self.payload()))
    }

    @Test func nonFiniteAnchorSignsOut() {
        // A corrupted/tampered anchor that parses to a non-finite Date
        // (`Date(timeIntervalSince1970: .infinity)`) must NOT pin the DJ to
        // signed-in forever: `now.timeIntervalSince(+inf-date)` is `-inf`, which
        // is `< window`, so without a finite-elapsed guard the bounded window is
        // defeated. Fail closed.
        let farFuture = Date(timeIntervalSince1970: .infinity)
        let decision = OfflineSessionPolicy.decide(
            hasStoredSession: true,
            cachedPayload: Self.payload(),
            lastValidatedAt: farFuture,
            now: Self.now,
            window: Self.window
        )
        #expect(decision == .signedOut)
    }

    @Test func defaultWindowIsThirtyDays() {
        #expect(OfflineSessionPolicy.defaultWindow == 30 * 24 * 60 * 60)
    }

    @Test func diacriticRoleBearingPayloadRoundTripsThroughDecision() {
        let payload = JWTPayload(
            sub: "Hermanos Gutiérrez",
            email: "hermanos@wxyc.org",
            role: "md",
            exp: Self.now.addingTimeInterval(3600)
        )
        let decision = OfflineSessionPolicy.decide(
            hasStoredSession: true,
            cachedPayload: payload,
            lastValidatedAt: Self.now.addingTimeInterval(-1000),
            now: Self.now
        )
        guard case let .signedIn(returned) = decision else {
            Issue.record("expected signedIn, got \(decision)")
            return
        }
        #expect(returned == payload)
        #expect(returned.sub == "Hermanos Gutiérrez")
        #expect(returned.role == "md")
    }
}
