//
//  LibrarySearchTests.swift
//  WXYCAPITests
//
//  Pins the online-first / offline-fallback routing matrix (issue #58): a live
//  server hit is reported as `.server`; a failed online request or an offline
//  monitor routes to the local FTS clone and is reported as `.local`; a nil or
//  empty store offline yields an empty `.local` result.
//
//  Created by Jake on 06/28/26.
//  Copyright © 2026 WXYC. All rights reserved.
//

import Foundation
import Testing
@testable import WXYCAPI

@Suite("LibrarySearch", .serialized)
@MainActor
struct LibrarySearchTests {
    private static let config = WXYCAPIConfiguration.localDevelopment

    /// A signed-in APIClient over a scripted session (mirrors the helper in
    /// APIClientTests). The session-token restore consumes the first stub.
    /// `onOutcome` defaults to nil (most tests don't care); the half-open probe
    /// tests wire it to a `ConnectivityMonitor` so a probe's real transport
    /// result flows through the ordinary outcome hook, exactly as production
    /// wires it in `AppDependencies`.
    private static func makeSignedInClient(
        onOutcome: (@Sendable (Bool) -> Void)? = nil
    ) async throws -> (APIClient, StubRequestSession) {
        let session = StubRequestSession()
        let storage = InMemoryTokenStorage()
        try storage.save("session-abc", for: .sessionToken)
        let auth = AuthService(configuration: config, storage: storage, session: session)
        session.enqueue(StubRequestSession.Stub(
            statusCode: 200,
            body: Data(#"{"token":"\#(Fixtures.jwt())"}"#.utf8)
        ))
        await auth.restoreSession()
        let client = APIClient(configuration: config, session: session, authService: auth, onOutcome: onOutcome)
        return (client, session)
    }

    /// A signed-in APIClient whose post-restore transport is a
    /// ``BlockingRequestSession`` — used by the no-stall half-open-probe test,
    /// where the probe's own request must be able to hang forever without the
    /// test hanging with it. Auth restore runs over its own `StubRequestSession`
    /// (unblocked), so only the `searchLibrary` calls that follow are affected.
    private static func makeSignedInBlockingClient(
        blocking session: BlockingRequestSession,
        onOutcome: (@Sendable (Bool) -> Void)? = nil
    ) async throws -> APIClient {
        let authSession = StubRequestSession()
        let storage = InMemoryTokenStorage()
        try storage.save("session-abc", for: .sessionToken)
        let auth = AuthService(configuration: config, storage: storage, session: authSession)
        authSession.enqueue(StubRequestSession.Stub(
            statusCode: 200,
            body: Data(#"{"token":"\#(Fixtures.jwt())"}"#.utf8)
        ))
        await auth.restoreSession()
        return APIClient(configuration: config, session: session, authService: auth, onOutcome: onOutcome)
    }

    /// Let any background work (a fire-and-forget half-open probe `Task`, in
    /// particular) get scheduled time on the executor before an assertion.
    /// Generous on purpose: a probe's failure/success reaches
    /// `ConnectivityMonitor` through its ordered `ingest` -> internal FIFO
    /// consumer `Task` -> `apply` chain, one more hop *after* the request
    /// StubRequestSession records — draining only on the request count (as
    /// `drain(until:)` below does) can return before that hop lands, which
    /// matters whenever a test is about to move the injected clock again (a
    /// too-early clock advance would apply to a `now()` call that hasn't
    /// happened yet, corrupting the cooldown anchor the pending `apply` is
    /// about to record). Everything here runs cooperatively on the main
    /// actor's serial executor, so this is deterministic, not a sleep.
    private func settle() async {
        for _ in 0..<200 { await Task.yield() }
    }

    /// Yield (bounded) until `condition` holds. Used where an unknown number of
    /// hops must complete before a background probe's outcome is observable —
    /// the bound just prevents a hang if a regression means it never becomes
    /// true (the caller's `#expect` then fails).
    private func drain(until condition: @MainActor () -> Bool) async {
        for _ in 0..<1000 {
            if condition() { return }
            await Task.yield()
        }
    }

    @Test func onlineServerHitReturnsServerResults() async throws {
        let (client, session) = try await Self.makeSignedInClient()
        session.enqueue(StubRequestSession.Stub(
            statusCode: 200,
            body: Data("[\(Fixtures.juanaMolinaSearchResult)]".utf8)
        ))
        let store = SpyCatalogStore(rows: try Fixtures.catalogRows())
        let search = LibrarySearch(
            api: client, catalogStore: store, connectivity: ConnectivityMonitor(initiallyOnline: true)
        )

        let outcome = await search.search(query: "juana", limit: 25)

        #expect(outcome.source == .server)
        #expect(outcome.results.map(\.id) == [100])
    }

    @Test func onlineServerFailureFallsBackToLocal() async throws {
        let (client, session) = try await Self.makeSignedInClient()
        session.enqueue(StubRequestSession.Stub(statusCode: 500, body: Data(#"{"error":"boom"}"#.utf8)))
        let store = SpyCatalogStore(rows: try Fixtures.catalogRows())
        let search = LibrarySearch(
            api: client, catalogStore: store, connectivity: ConnectivityMonitor(initiallyOnline: true)
        )

        let outcome = await search.search(query: "juana", limit: 25)

        #expect(outcome.source == .local)
        #expect(outcome.results.map(\.id) == [100])
    }

    @Test func offlineGoesStraightToLocalWithoutHittingTheServer() async throws {
        let (client, session) = try await Self.makeSignedInClient()
        let baseline = session.recordedRequests.count
        let store = SpyCatalogStore(rows: try Fixtures.catalogRows())
        let search = LibrarySearch(
            api: client, catalogStore: store, connectivity: ConnectivityMonitor(initiallyOnline: false)
        )

        let outcome = await search.search(query: "juana", limit: 25)

        #expect(outcome.source == .local)
        #expect(outcome.results.map(\.id) == [100])
        // Offline must never touch the network.
        #expect(session.recordedRequests.count == baseline)
    }

    @Test func offlineWithNilStoreYieldsEmptyLocal() async throws {
        let (client, _) = try await Self.makeSignedInClient()
        let search = LibrarySearch(
            api: client, catalogStore: nil, connectivity: ConnectivityMonitor(initiallyOnline: false)
        )

        let outcome = await search.search(query: "juana", limit: 25)

        #expect(outcome.source == .local)
        #expect(outcome.results.isEmpty)
    }

    @Test func offlineWithNoMatchYieldsEmptyLocal() async throws {
        let (client, _) = try await Self.makeSignedInClient()
        let store = SpyCatalogStore(rows: try Fixtures.catalogRows())
        let search = LibrarySearch(
            api: client, catalogStore: store, connectivity: ConnectivityMonitor(initiallyOnline: false)
        )

        let outcome = await search.search(query: "no-such-artist", limit: 25)

        #expect(outcome.source == .local)
        #expect(outcome.results.isEmpty)
    }

    @Test func nilStoreOnlineStillServesServerResults() async throws {
        let (client, session) = try await Self.makeSignedInClient()
        session.enqueue(StubRequestSession.Stub(
            statusCode: 200,
            body: Data("[\(Fixtures.juanaMolinaSearchResult)]".utf8)
        ))
        let search = LibrarySearch(
            api: client, catalogStore: nil, connectivity: ConnectivityMonitor(initiallyOnline: true)
        )

        let outcome = await search.search(query: "juana", limit: 25)

        #expect(outcome.source == .server)
        #expect(outcome.results.map(\.id) == [100])
    }

    // MARK: Half-open probe (issue #81)

    @Test func offlineSearchBeforeCooldownElapsedNeverProbesTheServer() async throws {
        let clock = ManualClock()
        let connectivity = ConnectivityMonitor(initiallyOnline: false, probeCooldown: 30, now: clock.provider)
        let (client, session) = try await Self.makeSignedInClient()
        let store = SpyCatalogStore(rows: try Fixtures.catalogRows())
        let search = LibrarySearch(api: client, catalogStore: store, connectivity: connectivity)
        let baseline = session.recordedRequests.count

        clock.advance(by: 29) // one second short of the cooldown

        let outcome = await search.search(query: "juana", limit: 25)

        #expect(outcome.source == .local)
        #expect(outcome.results.map(\.id) == [100])
        await settle()
        #expect(session.recordedRequests.count == baseline)
    }

    @Test func offlineSearchAfterCooldownFiresABackgroundProbeAndUnlatchesOnSuccess() async throws {
        let clock = ManualClock()
        let connectivity = ConnectivityMonitor(initiallyOnline: false, probeCooldown: 30, now: clock.provider)
        let (client, session) = try await Self.makeSignedInClient(onOutcome: { success in
            connectivity.ingest(isOnline: success)
        })
        session.enqueue(StubRequestSession.Stub(
            statusCode: 200,
            body: Data("[\(Fixtures.juanaMolinaSearchResult)]".utf8)
        ))
        let store = SpyCatalogStore(rows: try Fixtures.catalogRows())
        let search = LibrarySearch(api: client, catalogStore: store, connectivity: connectivity)

        clock.advance(by: 30)

        let outcome = await search.search(query: "juana", limit: 25)

        // This search's own results still come from the clone — the probe
        // exists to produce a connectivity signal, not to serve this query.
        #expect(outcome.source == .local)
        #expect(outcome.results.map(\.id) == [100])

        // The probe fired in the background reaches the server and un-latches
        // connectivity through the ordinary outcome hook, reconnect edge
        // included — no extra plumbing required.
        await drain(until: { connectivity.isOnline })
        #expect(connectivity.isOnline == true)
    }

    @Test func offlineHalfOpenProbeNeverStallsTheLocalResultTheDJSees() async throws {
        let clock = ManualClock()
        let connectivity = ConnectivityMonitor(initiallyOnline: false, probeCooldown: 30, now: clock.provider)
        let blockingSession = BlockingRequestSession(body: Data("[]".utf8))
        let client = try await Self.makeSignedInBlockingClient(
            blocking: blockingSession,
            onOutcome: { success in connectivity.ingest(isOnline: success) }
        )
        let store = SpyCatalogStore(rows: try Fixtures.catalogRows())
        let search = LibrarySearch(api: client, catalogStore: store, connectivity: connectivity)

        clock.advance(by: 30)

        // The probe's request is parked forever inside blockingSession — if
        // `search` awaited it, this test would hang. It doesn't hang, which is
        // the proof: the local results are what render, promptly.
        let outcome = await search.search(query: "juana", limit: 25)

        #expect(outcome.source == .local)
        #expect(outcome.results.map(\.id) == [100])

        // Confirm the probe genuinely fired (not silently skipped) before
        // releasing it so the background task can finish cleanly.
        await blockingSession.waitForFirstRequest()
        #expect(blockingSession.requestCount == 1)
        blockingSession.release()
    }

    @Test func repeatedOfflineSearchesInsideOneCooldownWindowProduceAtMostOneServerAttempt() async throws {
        let clock = ManualClock()
        let connectivity = ConnectivityMonitor(initiallyOnline: false, probeCooldown: 30, now: clock.provider)
        let (client, session) = try await Self.makeSignedInClient(onOutcome: { success in
            connectivity.ingest(isOnline: success)
        })
        session.enqueue(failure: URLError(.notConnectedToInternet)) // the one claimed probe fails
        let store = SpyCatalogStore(rows: try Fixtures.catalogRows())
        let search = LibrarySearch(api: client, catalogStore: store, connectivity: connectivity)
        let baseline = session.recordedRequests.count

        clock.advance(by: 30)

        // Three keystrokes' worth of searches inside the same cooldown window.
        _ = await search.search(query: "juana", limit: 25)
        _ = await search.search(query: "juana", limit: 25)
        _ = await search.search(query: "juana", limit: 25)

        await drain(until: { session.recordedRequests.count > baseline })
        await settle() // let a wrongly-fired second/third probe have a chance to show up
        #expect(session.recordedRequests.count == baseline + 1)
        // The failed probe re-latches (it already was latched) without ever
        // producing a spurious reconnect edge.
        #expect(connectivity.isOnline == false)
    }

    @Test func failedProbeRestartsTheCooldownBeforeAnotherAttemptIsAllowed() async throws {
        let clock = ManualClock()
        let connectivity = ConnectivityMonitor(initiallyOnline: false, probeCooldown: 30, now: clock.provider)
        let (client, session) = try await Self.makeSignedInClient(onOutcome: { success in
            connectivity.ingest(isOnline: success)
        })
        session.enqueue(failure: URLError(.notConnectedToInternet)) // first probe fails
        session.enqueue(StubRequestSession.Stub(
            statusCode: 200,
            body: Data("[\(Fixtures.juanaMolinaSearchResult)]".utf8)
        )) // second probe (after the restarted cooldown) succeeds
        let store = SpyCatalogStore(rows: try Fixtures.catalogRows())
        let search = LibrarySearch(api: client, catalogStore: store, connectivity: connectivity)
        let baseline = session.recordedRequests.count

        clock.advance(by: 30)
        _ = await search.search(query: "juana", limit: 25)
        await drain(until: { session.recordedRequests.count == baseline + 1 })
        // Let the failure fully propagate through the monitor's FIFO consumer
        // (see settle()'s doc) before the clock moves again — otherwise the
        // pending `apply` could capture `now()` well past the intended anchor.
        await settle()
        #expect(connectivity.isOnline == false)

        // 29s after the failure: the cooldown restarted from the failure, not
        // the original latch, so this is still inside the window.
        clock.advance(by: 29)
        _ = await search.search(query: "juana", limit: 25)
        await settle()
        #expect(session.recordedRequests.count == baseline + 1)

        // The remaining second completes the restarted cooldown.
        clock.advance(by: 1)
        _ = await search.search(query: "juana", limit: 25)
        await drain(until: { session.recordedRequests.count == baseline + 2 })
        await drain(until: { connectivity.isOnline })
        #expect(connectivity.isOnline == true)
    }

    @Test func aProbeThatThrowsBeforeReachingTheTransportDoesNotStrandTheMonitor() async throws {
        // The end-to-end shape of the silent-probe hazard `ConnectivityMonitor`
        // guards against. `APIClient.perform` resolves a bearer token *before*
        // it touches the network, so a signed-out `AuthService` throws
        // `.notSignedIn` with no request fired and therefore no `onOutcome`
        // call — the claimed allowance is spent, yet nothing moves the
        // monitor's offline anchor. Because the claim is timestamped rather
        // than held until an outcome arrives, this costs one cooldown, not the
        // whole half-open mechanism.
        let clock = ManualClock()
        let connectivity = ConnectivityMonitor(initiallyOnline: false, probeCooldown: 30, now: clock.provider)
        let session = StubRequestSession()
        let auth = AuthService(
            configuration: Self.config, storage: InMemoryTokenStorage(), session: session
        ) // no session token: currentJWT() throws before any transport
        let client = APIClient(
            configuration: Self.config,
            session: session,
            authService: auth,
            onOutcome: { success in connectivity.ingest(isOnline: success) }
        )
        let store = SpyCatalogStore(rows: try Fixtures.catalogRows())
        let search = LibrarySearch(api: client, catalogStore: store, connectivity: connectivity)

        clock.advance(by: 30)
        let outcome = await search.search(query: "juana", limit: 25)
        await settle()

        // The local results still render, and the probe never reached the wire.
        #expect(outcome.source == .local)
        #expect(outcome.results.map(\.id) == [100])
        #expect(session.recordedRequests.isEmpty)
        #expect(connectivity.isOnline == false)

        // Still rate-limited inside the window the silent claim opened…
        clock.advance(by: 29)
        #expect(connectivity.isHalfOpen == false)
        _ = await search.search(query: "juana", limit: 25)
        await settle()
        #expect(session.recordedRequests.isEmpty)

        // …but the mechanism is alive rather than stranded: one cooldown after
        // the silent claim the allowance is offered again, and the next search
        // takes it. (That a *reaching* probe then un-latches is pinned by
        // offlineSearchAfterCooldownFiresABackgroundProbeAndUnlatchesOnSuccess.)
        clock.advance(by: 1)
        #expect(connectivity.isHalfOpen == true)
        _ = await search.search(query: "juana", limit: 25)
        await settle()
        #expect(connectivity.isHalfOpen == false)
    }
}
