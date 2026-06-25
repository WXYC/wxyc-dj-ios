//
//  GatedAuthSession.swift
//  WXYCAPITests
//
//  A RequestSession that serves most fetches instantly from a FIFO of stubs but
//  can GATE the next `…/token` request — parking that one fetch until released,
//  so a test can interleave a concurrent re-sign-in while a stale JWT refresh is
//  suspended mid-flight. Built for the issue-#53 lazy-demotion race: currentJWT()
//  must not clobber a session that was replaced while its refresh was awaiting.
//  StubRequestSession returns instantly, so two refreshes never truly overlap
//  there; this primitive forces the overlap deterministically. Lock-guarded
//  Sendable (cf. BlockingRequestSession).
//
//  Created by Jake on 06/25/26.
//  Copyright © 2026 WXYC. All rights reserved.
//

import Foundation
import os
@testable import WXYCAPI

public final class GatedAuthSession: RequestSession, @unchecked Sendable {
    private struct State {
        var instant: [StubRequestSession.Stub] = []
        var recorded: [URLRequest] = []
        // Gate (one-shot): the next `…/token` request parks here until released.
        var armed = false
        var gatedStub = StubRequestSession.Stub(statusCode: 401)
        var arrived = false
        var arrivalWaiters: [CheckedContinuation<Void, Never>] = []
        var released = false
        var parked: CheckedContinuation<Void, Never>?
    }

    private let state = OSAllocatedUnfairLock(initialState: State())

    public init() {}

    /// Queue a response served instantly, FIFO, to any request that isn't the
    /// currently-gated token fetch.
    public func enqueueInstant(_ stub: StubRequestSession.Stub) {
        state.withLock { $0.instant.append(stub) }
    }

    /// Arm the gate: the next `…/token` request parks until ``releaseGate()``,
    /// then returns `stub`. One-shot — once that request arrives the gate
    /// disarms, so later token fetches (e.g. a re-sign-in's exchange) are instant.
    public func armGate(returning stub: StubRequestSession.Stub) {
        state.withLock {
            $0.armed = true
            $0.gatedStub = stub
            $0.released = false
            $0.arrived = false
        }
    }

    public var recordedRequests: [URLRequest] { state.withLock { $0.recorded } }

    /// Suspends until the gated token fetch has arrived and parked.
    public func waitForGatedArrival() async {
        await withCheckedContinuation { continuation in
            let resumeNow: Bool = state.withLock { st in
                if st.arrived { return true }
                st.arrivalWaiters.append(continuation)
                return false
            }
            if resumeNow { continuation.resume() }
        }
    }

    /// Release the parked gated fetch so it returns its armed response. Safe to
    /// call before the fetch parks — a `released` flag lets the later park
    /// resume immediately (cf. BlockingRequestSession).
    public func releaseGate() {
        let parked: CheckedContinuation<Void, Never>? = state.withLock { st in
            st.released = true
            defer { st.parked = nil }
            return st.parked
        }
        parked?.resume()
    }

    public func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        let isToken = request.url?.path.hasSuffix("/token") ?? false

        enum Action { case instant(StubRequestSession.Stub); case gated(StubRequestSession.Stub); case noStub }

        let (action, arrivalWaiters): (Action, [CheckedContinuation<Void, Never>]) = state.withLock { st in
            st.recorded.append(request)
            if isToken, st.armed {
                st.armed = false
                st.arrived = true
                let waiters = st.arrivalWaiters
                st.arrivalWaiters = []
                return (.gated(st.gatedStub), waiters)
            }
            guard !st.instant.isEmpty else { return (.noStub, []) }
            return (.instant(st.instant.removeFirst()), [])
        }
        for waiter in arrivalWaiters { waiter.resume() }

        let stub: StubRequestSession.Stub
        switch action {
        case .noStub:
            throw StubRequestSession.StubError.noMoreStubs
        case .instant(let s):
            stub = s
        case .gated(let s):
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                let resumeNow: Bool = state.withLock { st in
                    if st.released { return true }
                    st.parked = continuation
                    return false
                }
                if resumeNow { continuation.resume() }
            }
            stub = s
        }

        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: stub.statusCode,
            httpVersion: "HTTP/1.1",
            headerFields: stub.headers
        )!
        return (stub.body, response)
    }
}
