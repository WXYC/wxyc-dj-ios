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

        await settle()
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

        monitor.noteOutcome(success: false) // -> offline
        monitor.noteOutcome(success: true)  // EDGE 1
        monitor.noteOutcome(success: false) // -> offline
        monitor.noteOutcome(success: true)  // EDGE 2

        await settle()
        #expect(box.count == 2)
        collector.cancel()
    }
}
