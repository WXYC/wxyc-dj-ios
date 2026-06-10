//
//  StubRequestSession.swift
//  WXYCDJTests
//
//  Scripted RequestSession that returns canned (Data, HTTPURLResponse) pairs
//  in FIFO order. Duplicated from WXYCAPITests/Support so the app-target test
//  bundle doesn't need to depend on another bundle's source. Kept in sync by
//  hand for now; if a third bundle ever needs it we should promote it to a
//  shared SPM test-support target.
//
//  Created by Jake on 5/19/26.
//  Copyright © 2026 WXYC. All rights reserved.
//

import Foundation
import os
@testable import WXYCAPI

final class StubRequestSession: RequestSession {
    struct Stub: Sendable {
        let statusCode: Int
        let headers: [String: String]
        let body: Data

        init(statusCode: Int = 200, headers: [String: String] = [:], body: Data = Data()) {
            self.statusCode = statusCode
            self.headers = headers
            self.body = body
        }
    }

    private struct State {
        var stubs: [Stub] = []
        var recorded: [URLRequest] = []
    }

    private let state = OSAllocatedUnfairLock<State>(initialState: State())

    init() {}

    func enqueue(_ stub: Stub) {
        state.withLock { $0.stubs.append(stub) }
    }

    var recordedRequests: [URLRequest] {
        state.withLock { $0.recorded }
    }

    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        let stub: Stub = try state.withLock { state in
            state.recorded.append(request)
            guard !state.stubs.isEmpty else {
                throw StubError.noMoreStubs
            }
            return state.stubs.removeFirst()
        }
        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: stub.statusCode,
            httpVersion: "HTTP/1.1",
            headerFields: stub.headers
        )!
        return (stub.body, response)
    }

    enum StubError: Error, Sendable {
        case noMoreStubs
    }
}
