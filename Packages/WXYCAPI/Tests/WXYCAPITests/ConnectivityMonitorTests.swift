//
//  ConnectivityMonitorTests.swift
//  WXYCAPITests
//
//  Pins ConnectivityMonitor's behavior: path updates flip isOnline; a transport
//  failure latches offline even under a satisfied path and a later success (or a
//  fresh satisfied path) restores it (last-write-wins); and the reconnects
//  AsyncStream yields exactly one edge per offline→online transition (cause-
//  agnostic) and none otherwise.
//
//  Created by Jake on 6/26/26.
//  Copyright © 2026 WXYC. All rights reserved.
//

import Testing
@testable import WXYCAPI

@Suite("ConnectivityMonitor")
@MainActor
struct ConnectivityMonitorTests {
    /// A main-actor counter the reconnect-edge collector increments. A reference
    /// type so the escaping `Task` closure can mutate it; main-actor-isolated so
    /// it shares the suite's executor and stays data-race-free.
    @MainActor private final class EdgeBox {
        var count = 0
    }

    /// Let any `Task { @MainActor }` hops scheduled by a path push or a stream
    /// yield run to a quiescent point. Everything here is main-actor-isolated, so
    /// a handful of yields drains the enqueued continuations deterministically.
    private func settle() async {
        for _ in 0..<5 { await Task.yield() }
    }

    /// Yield (bounded) until `condition` holds, draining the `signals` consumer's
    /// enqueued main-actor work. Returns once satisfied; the bound just prevents a
    /// hang if a regression means it never becomes true (the caller's `#expect`
    /// then fails). Used where an unknown number of consumer hops must complete —
    /// unlike a fixed yield count, this waits long enough without masking a
    /// reorder (a reorder settles on the wrong value, so the condition stays false
    /// and the test fails).
    private func drain(until condition: @MainActor () -> Bool) async {
        for _ in 0..<1000 {
            if condition() { return }
            await Task.yield()
        }
    }

    // MARK: Initial state

    @Test func startsOptimisticallyOnline() {
        #expect(ConnectivityMonitor().isOnline == true)
    }

    @Test func honorsInitiallyOfflineSeed() {
        #expect(ConnectivityMonitor(initiallyOnline: false).isOnline == false)
    }

    // MARK: Path updates

    @Test func pathSatisfiedThenUnsatisfiedFlipsIsOnline() async {
        let monitor = ConnectivityMonitor()
        let provider = StubPathProvider()
        monitor.start(pathProvider: provider)

        provider.send(satisfied: true)
        await settle()
        #expect(monitor.isOnline == true)

        provider.send(satisfied: false)
        await settle()
        #expect(monitor.isOnline == false)
    }

    // MARK: Outcome correction + last-write-wins precedence

    @Test func transportFailureLatchesOfflineUnderSatisfiedPathThenSuccessRestores() async {
        let monitor = ConnectivityMonitor()
        let provider = StubPathProvider()
        monitor.start(pathProvider: provider)

        provider.send(satisfied: true)
        await settle()
        #expect(monitor.isOnline == true)

        // A transport failure overrides a still-satisfied OS path (captive
        // portal / backend down).
        monitor.noteOutcome(success: false)
        #expect(monitor.isOnline == false)

        // A later successful outcome restores online.
        monitor.noteOutcome(success: true)
        #expect(monitor.isOnline == true)
    }

    @Test func freshSatisfiedPathRestoresOnlineAfterFailure() async {
        let monitor = ConnectivityMonitor()
        let provider = StubPathProvider()
        monitor.start(pathProvider: provider)
        provider.send(satisfied: true)
        await settle()

        monitor.noteOutcome(success: false)
        #expect(monitor.isOnline == false)

        // last-write-wins: a fresh satisfied path update also restores online,
        // not only a successful outcome.
        provider.send(satisfied: true)
        await settle()
        #expect(monitor.isOnline == true)
    }

    @Test func unsatisfiedPathOverridesEarlierSuccess() async {
        // last-write-wins in the other direction: a path dropping after a
        // successful outcome goes offline.
        let monitor = ConnectivityMonitor()
        let provider = StubPathProvider()
        monitor.start(pathProvider: provider)

        monitor.noteOutcome(success: true)
        #expect(monitor.isOnline == true)

        provider.send(satisfied: false)
        await settle()
        #expect(monitor.isOnline == false)
    }

    // MARK: Reconnect edge

    @Test func reconnectsYieldsExactlyOneEdgeOnOfflineToOnline() async {
        let monitor = ConnectivityMonitor()
        let box = EdgeBox()
        let collector = Task { @MainActor in
            for await _ in monitor.reconnects { box.count += 1 }
        }
        await settle() // collector subscribes and suspends on the empty buffer

        monitor.noteOutcome(success: false) // online -> offline: no edge
        monitor.noteOutcome(success: true)  // offline -> online: EDGE
        monitor.noteOutcome(success: true)  // online -> online: no edge

        await drain(until: { box.count == 1 })
        #expect(box.count == 1)
        collector.cancel()
    }

    @Test func reconnectsYieldsNothingWithoutAnOfflineToOnlineTransition() async {
        let monitor = ConnectivityMonitor() // starts online
        let box = EdgeBox()
        let collector = Task { @MainActor in
            for await _ in monitor.reconnects { box.count += 1 }
        }
        await settle()

        monitor.noteOutcome(success: true) // online -> online: no edge
        monitor.noteOutcome(success: true) // online -> online: no edge

        await settle()
        #expect(box.count == 0)
        collector.cancel()
    }

    @Test func reconnectEdgeIsCauseAgnosticAndFiresOnPathRecovery() async {
        let monitor = ConnectivityMonitor()
        let provider = StubPathProvider()
        monitor.start(pathProvider: provider)
        let box = EdgeBox()
        let collector = Task { @MainActor in
            for await _ in monitor.reconnects { box.count += 1 }
        }
        await settle()

        provider.send(satisfied: false) // online -> offline: no edge
        await settle()
        provider.send(satisfied: true)  // offline -> online: EDGE (path-driven)
        await settle()

        #expect(box.count == 1)
        collector.cancel()
    }

    @Test func reconnectsYieldsOncePerDistinctTransition() async {
        let monitor = ConnectivityMonitor()
        let box = EdgeBox()
        let collector = Task { @MainActor in
            for await _ in monitor.reconnects { box.count += 1 }
        }
        await settle()

        // Drain between the two reconnect edges: the stream coalesces newest-1, so
        // a consumer that keeps pace (the realistic case — reconnects are seconds
        // apart) sees one wake per transition; the late-subscriber backlog test
        // covers the coalescing direction.
        monitor.noteOutcome(success: false) // -> offline
        monitor.noteOutcome(success: true)  // EDGE 1
        await drain(until: { box.count == 1 })

        monitor.noteOutcome(success: false) // -> offline
        monitor.noteOutcome(success: true)  // EDGE 2
        await drain(until: { box.count == 2 })

        #expect(box.count == 2)
        collector.cancel()
    }

    // MARK: Ordered ingestion (last-write-wins across off-actor signals)

    /// The production ingress (path callback + APIClient outcome hook) lands on
    /// arbitrary threads, so it funnels through ``ConnectivityMonitor/ingest(isOnline:)``
    /// rather than each spawning its own `Task { @MainActor }` — independently
    /// created tasks have no FIFO guarantee on the main actor, so a stale signal
    /// could otherwise apply after a fresher one and break last-write-wins. A
    /// burst of ingests must settle to the **last** value submitted.
    @Test func ingestAppliesSignalsInSubmissionOrder() async {
        let monitor = ConnectivityMonitor()
        // Submit a long alternating burst from a non-isolated context, ending on
        // `false`. The single serial consumer applies them in submission order,
        // so the last value wins; if any pair reordered, the final state could be
        // `true` and `drain(until:)` would never see `false`.
        for i in 0..<50 { monitor.ingest(isOnline: i % 2 == 0) }
        monitor.ingest(isOnline: false)
        await drain(until: { monitor.isOnline == false })
        #expect(monitor.isOnline == false)
    }

    /// The other direction: a burst ending on `true` settles online, and the
    /// reconnect edge fires for the final offline→online crossing.
    @Test func ingestEndingOnlineSettlesOnlineWithReconnectEdge() async {
        let monitor = ConnectivityMonitor()
        let box = EdgeBox()
        let collector = Task { @MainActor in
            for await _ in monitor.reconnects { box.count += 1 }
        }
        await settle()

        monitor.ingest(isOnline: false)
        monitor.ingest(isOnline: true)
        await drain(until: { monitor.isOnline == true && box.count == 1 })

        #expect(monitor.isOnline == true)
        #expect(box.count == 1)
        collector.cancel()
    }

    // MARK: Reconnect-stream buffering for a late subscriber (#61)

    /// `reconnects` coalesces for a *late* subscriber (the documented #61
    /// `BinSyncService` attaches after launch): a subscriber that starts after
    /// several historical reconnects must NOT receive the whole backlog at once
    /// (which would fire one queued-bin flush per historical edge). The stream is
    /// buffered newest-1, so a late subscriber sees at most one pending edge, not
    /// the full history.
    @Test func reconnectsDoesNotReplayFullBacklogToALateSubscriber() async {
        let monitor = ConnectivityMonitor()
        // Generate several reconnect edges with NO subscriber attached.
        for _ in 0..<5 {
            monitor.noteOutcome(success: false)
            monitor.noteOutcome(success: true) // each pair = one offline->online edge
        }

        // Now attach a late subscriber and drain whatever is buffered.
        let box = EdgeBox()
        let collector = Task { @MainActor in
            for await _ in monitor.reconnects { box.count += 1 }
        }
        await settle()

        // A newest-1 buffer replays at most one edge, not all five.
        #expect(box.count <= 1)
        collector.cancel()
    }

    // MARK: Half-open probe (issue #81)

    @Test func isHalfOpenIsFalseWhileOnline() {
        let clock = ManualClock()
        let monitor = ConnectivityMonitor(initiallyOnline: true, probeCooldown: 30, now: clock.provider)
        clock.advance(by: 100)
        #expect(monitor.isHalfOpen == false)
        #expect(monitor.consumeProbe() == false)
    }

    @Test func isHalfOpenIsFalseBeforeCooldownElapses() {
        let clock = ManualClock()
        let monitor = ConnectivityMonitor(initiallyOnline: true, probeCooldown: 30, now: clock.provider)
        monitor.noteOutcome(success: false)
        clock.advance(by: 29)
        #expect(monitor.isHalfOpen == false)
        #expect(monitor.consumeProbe() == false)
    }

    @Test func isHalfOpenBecomesTrueOnceCooldownElapses() {
        let clock = ManualClock()
        let monitor = ConnectivityMonitor(initiallyOnline: true, probeCooldown: 30, now: clock.provider)
        monitor.noteOutcome(success: false)
        clock.advance(by: 30)
        #expect(monitor.isHalfOpen == true)
    }

    @Test func consumeProbeClaimsAtMostOncePerCooldownWindow() {
        let clock = ManualClock()
        let monitor = ConnectivityMonitor(initiallyOnline: true, probeCooldown: 30, now: clock.provider)
        monitor.noteOutcome(success: false)
        clock.advance(by: 30)

        #expect(monitor.consumeProbe() == true)
        // The allowance is spent: a second caller inside the same window (no
        // further time passing, no new outcome) gets nothing.
        #expect(monitor.isHalfOpen == false)
        #expect(monitor.consumeProbe() == false)
    }

    @Test func failedProbeRestartsTheCooldown() {
        let clock = ManualClock()
        let monitor = ConnectivityMonitor(initiallyOnline: true, probeCooldown: 30, now: clock.provider)
        monitor.noteOutcome(success: false)
        clock.advance(by: 30)
        #expect(monitor.consumeProbe() == true)

        // The claimed probe's request fails, reported through the ordinary
        // outcome hook — still offline, but the cooldown restarts from here.
        monitor.noteOutcome(success: false)
        #expect(monitor.isHalfOpen == false)

        // The old cooldown boundary (60s from the very first failure) is not
        // enough on its own — only 30s have passed since the *restart*.
        clock.advance(by: 29)
        #expect(monitor.isHalfOpen == false)

        clock.advance(by: 1)
        #expect(monitor.isHalfOpen == true)
        #expect(monitor.consumeProbe() == true)
    }

    @Test func aClaimedProbeThatReportsNoOutcomeExpiresAfterOneCooldown() {
        // The claim must expire on *time*, not solely on an outcome arriving.
        // A claimed probe can throw before it ever reaches the transport —
        // `APIClient.perform` resolves a bearer token first, so a signed-out
        // `AuthService` throws `.notSignedIn` with no request fired and no
        // `onOutcome` call — and `offlineSince` only moves inside `apply`. If
        // the claim were released only by an outcome, one such silent probe
        // would strand the monitor offline forever with no further probes: the
        // very dead end issue #81 exists to remove.
        let clock = ManualClock()
        let monitor = ConnectivityMonitor(initiallyOnline: true, probeCooldown: 30, now: clock.provider)
        monitor.noteOutcome(success: false)
        clock.advance(by: 30)
        #expect(monitor.consumeProbe() == true)

        // The probe reports nothing at all. Still rate-limited within the window…
        clock.advance(by: 29)
        #expect(monitor.isHalfOpen == false)
        #expect(monitor.consumeProbe() == false)

        // …but a full cooldown after the *claim*, a fresh probe is allowed.
        clock.advance(by: 1)
        #expect(monitor.isHalfOpen == true)
        #expect(monitor.consumeProbe() == true)
    }

    @Test func silentProbesCostOneCooldownEachAndNeverExhaustTheMechanism() {
        let clock = ManualClock()
        let monitor = ConnectivityMonitor(initiallyOnline: true, probeCooldown: 30, now: clock.provider)
        monitor.noteOutcome(success: false)

        // Ten consecutive probes that never report an outcome still yield
        // exactly one allowance per cooldown, indefinitely.
        for _ in 0..<10 {
            clock.advance(by: 30)
            #expect(monitor.consumeProbe() == true)
            #expect(monitor.consumeProbe() == false)
        }
    }

    @Test func successfulProbeUnlatchesAndFiresTheReconnectEdgeExactlyOnce() async {
        let clock = ManualClock()
        let monitor = ConnectivityMonitor(initiallyOnline: true, probeCooldown: 30, now: clock.provider)
        let box = EdgeBox()
        let collector = Task { @MainActor in
            for await _ in monitor.reconnects { box.count += 1 }
        }
        await settle()

        monitor.noteOutcome(success: false)
        clock.advance(by: 30)
        #expect(monitor.consumeProbe() == true)

        monitor.noteOutcome(success: true)
        await drain(until: { box.count == 1 })

        #expect(monitor.isOnline == true)
        #expect(box.count == 1)
        #expect(monitor.isHalfOpen == false) // online now — nothing left to probe
        collector.cancel()
    }

    @Test func initiallyOfflineMonitorStartsItsOwnCooldownAtConstruction() {
        let clock = ManualClock()
        let monitor = ConnectivityMonitor(initiallyOnline: false, probeCooldown: 10, now: clock.provider)
        #expect(monitor.isHalfOpen == false)
        clock.advance(by: 10)
        #expect(monitor.isHalfOpen == true)
    }

    @Test func aFreshSatisfiedPathAfterAProbeClaimClearsTheHalfOpenState() async {
        // The half-open bookkeeping isn't probe-specific — any signal that
        // restores `isOnline` (not just a request outcome) must clear it, same
        // as the reconnect edge is cause-agnostic.
        let clock = ManualClock()
        let monitor = ConnectivityMonitor(initiallyOnline: true, probeCooldown: 30, now: clock.provider)
        let provider = StubPathProvider()
        monitor.start(pathProvider: provider)

        monitor.noteOutcome(success: false)
        clock.advance(by: 30)
        #expect(monitor.consumeProbe() == true)

        provider.send(satisfied: true)
        await settle()

        #expect(monitor.isOnline == true)
        #expect(monitor.isHalfOpen == false)
    }
}
