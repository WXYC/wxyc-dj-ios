//
//  StubRequestSession.swift
//  WXYCAPITests
//
//  A scripted RequestSession that returns canned (Data, HTTPURLResponse)
//  pairs in FIFO order. Records every request issued.
//
//  Created by Jake on 5/14/26.
//  Copyright © 2026 WXYC. All rights reserved.
//

import Foundation
import os
@testable import WXYCAPI

public final class StubRequestSession: RequestSession {
    public struct Stub: Sendable {
        public let statusCode: Int
        public let headers: [String: String]
        public let body: Data

        public init(statusCode: Int = 200, headers: [String: String] = [:], body: Data = Data()) {
            self.statusCode = statusCode
            self.headers = headers
            self.body = body
        }

        public static func json(_ object: some Encodable, status: Int = 200, headers: [String: String] = [:]) throws -> Stub {
            let data = try JSONEncoder().encode(object)
            return Stub(statusCode: status, headers: headers, body: data)
        }

        public static func rawJSON(_ string: String, status: Int = 200, headers: [String: String] = [:]) -> Stub {
            Stub(statusCode: status, headers: headers, body: Data(string.utf8))
        }
    }

    private struct State {
        var stubs: [Stub] = []
        var recorded: [URLRequest] = []
    }

    private let state = OSAllocatedUnfairLock<State>(initialState: State())

    public init() {}

    public func enqueue(_ stub: Stub) {
        state.withLock { $0.stubs.append(stub) }
    }

    public var recordedRequests: [URLRequest] {
        state.withLock { $0.recorded }
    }

    public func data(for request: URLRequest) async throws -> (Data, URLResponse) {
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

    public enum StubError: Error, Sendable {
        case noMoreStubs
    }
}
