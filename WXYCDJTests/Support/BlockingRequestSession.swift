//
//  BlockingRequestSession.swift
//  WXYCDJTests
//
//  A RequestSession that holds each fetch open until released, so a test can
//  keep a request in flight while it does something else. StubRequestSession
//  returns instantly, so a "superseded mid-flight" scenario can never actually
//  overlap with it — this is what lets SearchViewModelTests exercise the
//  post-await `Task.isCancelled` guard in `performSearch(_:)` (issue #108).
//  Lock-guarded Sendable.
//
//  Deliberately a copy of WXYCAPITests/Support/BlockingRequestSession.swift,
//  the same arrangement StubRequestSession.swift and Fixtures.swift already
//  have — the app-target bundle can't depend on another bundle's source. Kept
//  in sync by hand; promote all three to a shared SPM test-support target if a
//  third bundle ever needs them.
//
//  Created by Jake Bromberg on 08/24/26.
//  Copyright © 2026 WXYC. All rights reserved.
//

import Foundation
import os
@testable import WXYCAPI

final class BlockingRequestSession: RequestSession, @unchecked Sendable {
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

    init(body: Data) { self.body = body }

    var requestCount: Int { state.withLock { $0.requestCount } }

    /// Suspends until at least one `data(for:)` has been entered.
    func waitForFirstRequest() async {
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
    func release() {
        let toResume: [CheckedContinuation<Void, Never>] = state.withLock { st in
            st.released = true
            defer { st.blocked = [] }
            return st.blocked
        }
        for continuation in toResume { continuation.resume() }
    }

    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
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
