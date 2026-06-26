//
//  StubRequestSession.swift
//  WXYCAPITests
//
//  A scripted RequestSession that returns canned (Data, HTTPURLResponse)
//  pairs in FIFO order — or throws a canned transport error, for exercising
//  the offline / outcome-hook paths (#56, #57). Records every request issued.
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

    /// A scripted outcome: either a canned HTTP response or a thrown transport
    /// error (simulating `URLSession.data(for:)` failing before any response —
    /// the signal ``APIClient`` maps to `noteOutcome(success: false)`).
    private enum Outcome {
        case response(Stub)
        case failure(any Error)
    }

    private struct State {
        var outcomes: [Outcome] = []
        var recorded: [URLRequest] = []
    }

    private let state = OSAllocatedUnfairLock<State>(initialState: State())

    public init() {}

    public func enqueue(_ stub: Stub) {
        state.withLock { $0.outcomes.append(.response(stub)) }
    }

    /// Enqueue a transport error to be thrown for the next request, in FIFO order
    /// alongside response stubs. Defaults to a not-connected `URLError`.
    public func enqueue(failure error: any Error = URLError(.notConnectedToInternet)) {
        state.withLock { $0.outcomes.append(.failure(error)) }
    }

    public var recordedRequests: [URLRequest] {
        state.withLock { $0.recorded }
    }

    public func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        let outcome: Outcome = try state.withLock { state in
            state.recorded.append(request)
            guard !state.outcomes.isEmpty else {
                throw StubError.noMoreStubs
            }
            return state.outcomes.removeFirst()
        }
        switch outcome {
        case .failure(let error):
            throw error
        case .response(let stub):
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: stub.statusCode,
                httpVersion: "HTTP/1.1",
                headerFields: stub.headers
            )!
            return (stub.body, response)
        }
    }

    public enum StubError: Error, Sendable {
        case noMoreStubs
    }
}
