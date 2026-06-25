//
//  GatedSearchableIndex.swift
//  WXYCAPITests
//
//  A SearchableIndexing double for the both-directions serialization tests (issue
//  #44). It records each batch op into a SHARED ordered event log (the real named
//  index is shared across handles, so the indexers makeIndexer() returns must share
//  one log) and can PAUSE a chosen op on a Gate, so a test holds one index touch
//  mid-flight, fires the other, and asserts via the log that they never interleave.
//  Lock-guarded Sendable, matching the other doubles.
//
//  Created by Jake on 06/24/26.
//  Copyright © 2026 WXYC. All rights reserved.
//

import CoreSpotlight
import Foundation
import os
@testable import WXYCAPI

/// An ordered, cross-handle record of the batch ops the indexer drove — so a test
/// can assert no reindex `begin`…`end` brackets a lazy upsert's write, and vice-versa.
final class SpotlightEventLog: @unchecked Sendable {
    enum Event: Equatable, Sendable {
        case begin
        case index([String])    // upserted uniqueIdentifiers
        case delete([String])
        case end
    }

    private let lock = OSAllocatedUnfairLock(initialState: [Event]())

    func record(_ event: Event) { lock.withLock { $0.append(event) } }
    var events: [Event] { lock.withLock { $0 } }
}

/// A one-shot rendezvous: the gated op calls ``arriveAndWait()`` (signalling it has
/// reached the gate, then suspending); the test calls ``waitUntilReached()`` to
/// learn the op is paused and ``proceed()`` to release it. Lets a test deterministically
/// hold one index touch in-flight while it fires the other.
final class Gate: @unchecked Sendable {
    private struct State {
        var reached = false
        var proceeded = false
        var reachedWaiters: [CheckedContinuation<Void, Never>] = []
        var blocked: [CheckedContinuation<Void, Never>] = []
    }

    private let lock = OSAllocatedUnfairLock(initialState: State())

    /// Called by the gated op: signal arrival, then suspend until `proceed()`.
    func arriveAndWait() async {
        let reachedWaiters: [CheckedContinuation<Void, Never>] = lock.withLock { state in
            state.reached = true
            defer { state.reachedWaiters = [] }
            return state.reachedWaiters
        }
        for waiter in reachedWaiters { waiter.resume() }

        await withCheckedContinuation { continuation in
            let resumeNow: Bool = lock.withLock { state in
                if state.proceeded { return true }
                state.blocked.append(continuation)
                return false
            }
            if resumeNow { continuation.resume() }
        }
    }

    /// Suspends until the gated op has arrived.
    func waitUntilReached() async {
        await withCheckedContinuation { continuation in
            let resumeNow: Bool = lock.withLock { state in
                if state.reached { return true }
                state.reachedWaiters.append(continuation)
                return false
            }
            if resumeNow { continuation.resume() }
        }
    }

    /// Release the gated op (and any future arrivals).
    func proceed() {
        let blocked: [CheckedContinuation<Void, Never>] = lock.withLock { state in
            state.proceeded = true
            defer { state.blocked = [] }
            return state.blocked
        }
        for waiter in blocked { waiter.resume() }
    }
}

final class GatedSearchableIndex: SearchableIndexing, @unchecked Sendable {
    /// Which op (if any) pauses on the gate. The gate fires **before** the op is
    /// recorded, so a paused op's effect is not yet visible in the log — that is
    /// what lets the test prove the *other* operation did (broken) or did not
    /// (serialized) slip in while this one was held.
    enum Op: Sendable { case index, delete, end }

    private let log: SpotlightEventLog
    private let gateOp: Op?
    private let gate: Gate?
    private let clientState = OSAllocatedUnfairLock(initialState: Data?.none)

    init(log: SpotlightEventLog, gateOp: Op? = nil, gate: Gate? = nil, initialClientState: Data? = nil) {
        self.log = log
        self.gateOp = gateOp
        self.gate = gate
        clientState.withLock { $0 = initialClientState }
    }

    func beginBatch() {
        // beginBatch is synchronous in the protocol, so it is never gated (neither
        // test needs to pause at begin); it just records.
        log.record(.begin)
    }

    func indexItems(_ items: [CSSearchableItem]) async throws {
        if gateOp == .index { await gate?.arriveAndWait() }
        log.record(.index(items.map { $0.uniqueIdentifier ?? "?" }))
    }

    func deleteItems(withIdentifiers identifiers: [String]) async throws {
        if gateOp == .delete { await gate?.arriveAndWait() }
        log.record(.delete(identifiers))
    }

    func endBatch(clientState newState: Data) async throws {
        if gateOp == .end { await gate?.arriveAndWait() }
        log.record(.end)
        clientState.withLock { $0 = newState }
    }

    func lastClientState() async throws -> Data? {
        clientState.withLock { $0 }
    }
}
