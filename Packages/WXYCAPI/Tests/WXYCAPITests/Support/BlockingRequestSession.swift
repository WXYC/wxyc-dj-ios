//
//  BlockingRequestSession.swift
//  WXYCAPITests
//
//  A RequestSession that holds each fetch open until released, so a test can force
//  two requests to be in-flight at once. StubRequestSession returns instantly, so
//  concurrent calls never truly overlap — this exercises the single-flight
//  (coalescing) branch of DiskThumbnailProvider (issue #44). Lock-guarded Sendable.
//
//  Created by Jake on 06/24/26.
//  Copyright © 2026 WXYC. All rights reserved.
//

import Foundation
import os
@testable import WXYCAPI

public final class BlockingRequestSession: RequestSession, @unchecked Sendable {
    private let body: Data

    private struct State {
        var requestCount = 0
        var released = false
        var firstRequestArrived = false
        /// Fetches parked until `release()`.
        var blocked: [CheckedContinuation<Void, Never>] = []
        /// A `waitForFirstRequest()` caller parked until the first fetch arrives.
        var firstRequestWaiters: [CheckedContinuation<Void, Never>] = []
    }

    private let state = OSAllocatedUnfairLock(initialState: State())

    public init(body: Data) { self.body = body }

    public var requestCount: Int { state.withLock { $0.requestCount } }

    /// Suspends until at least one `data(for:)` has been entered.
    public func waitForFirstRequest() async {
        await withCheckedContinuation { continuation in
            let resumeNow: Bool = state.withLock { st in
                if st.firstRequestArrived { return true }
                st.firstRequestWaiters.append(continuation)
                return false
            }
            if resumeNow { continuation.resume() }
        }
    }

    /// Let every parked (and future) fetch complete.
    public func release() {
        let toResume: [CheckedContinuation<Void, Never>] = state.withLock { st in
            st.released = true
            defer { st.blocked = [] }
            return st.blocked
        }
        for continuation in toResume { continuation.resume() }
    }

    public func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        let firstWaiters: [CheckedContinuation<Void, Never>] = state.withLock { st in
            st.requestCount += 1
            guard !st.firstRequestArrived else { return [] }
            st.firstRequestArrived = true
            defer { st.firstRequestWaiters = [] }
            return st.firstRequestWaiters
        }
        for continuation in firstWaiters { continuation.resume() }

        await withCheckedContinuation { continuation in
            let resumeNow: Bool = state.withLock { st in
                if st.released { return true }
                st.blocked.append(continuation)
                return false
            }
            if resumeNow { continuation.resume() }
        }

        let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
        return (body, response)
    }
}
