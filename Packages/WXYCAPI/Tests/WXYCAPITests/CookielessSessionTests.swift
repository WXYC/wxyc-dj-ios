//
//  CookielessSessionTests.swift
//  WXYCAPITests
//
//  Pins the no-cookie policy on its owner, so each consumer only has to pin
//  that it wraps rather than re-derive what wrapping guarantees.
//
//  Created by Jake on 8/18/26.
//  Copyright © 2026 WXYC. All rights reserved.
//

import Foundation
import Testing
@testable import WXYCAPI

@Suite("CookielessSession")
struct CookielessSessionTests {
    private static let url = URL(string: "https://api.wxyc.org/library/search")!

    /// The whole point of the type. A stored better-auth cookie replayed on a
    /// later request arms `originCheckMiddleware` — which enforces `Origin` only
    /// when a cookie is present — and a native client sends none, so the next
    /// sign-in is refused `403 MISSING_OR_NULL_ORIGIN` before any credential
    /// check. The full argument is on ``CookielessSession`` itself.
    @Test func suppressesCookieHandlingOnTheRequestThatLeaves() async throws {
        let base = StubRequestSession()
        base.enqueue(StubRequestSession.Stub(statusCode: 200))
        var request = URLRequest(url: Self.url)
        // Default is `true`; set it explicitly so the assertion can't pass by
        // accident on a platform whose default ever changes.
        request.httpShouldHandleCookies = true

        _ = try await CookielessSession(base).data(for: request)

        #expect(base.recordedRequests.first?.httpShouldHandleCookies == false)
    }

    /// Cookie handling is the *only* thing the decorator is allowed to touch —
    /// it sits under three consumers that each build a fully-formed request
    /// (bearer header, method, body, timeout), and silently altering any of that
    /// would be indistinguishable from a transport bug.
    @Test func forwardsEverythingElseUnmodified() async throws {
        let base = StubRequestSession()
        base.enqueue(StubRequestSession.Stub(statusCode: 200))
        var request = URLRequest(url: Self.url, timeoutInterval: 42)
        request.httpMethod = "POST"
        request.httpBody = Data(#"{"artist_name":"Juana Molina"}"#.utf8)
        request.setValue("Bearer jwt-abc", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        _ = try await CookielessSession(base).data(for: request)

        let sent = try #require(base.recordedRequests.first)
        #expect(sent.url == Self.url)
        #expect(sent.httpMethod == "POST")
        #expect(sent.httpBody == request.httpBody)
        #expect(sent.value(forHTTPHeaderField: "Authorization") == "Bearer jwt-abc")
        #expect(sent.value(forHTTPHeaderField: "Content-Type") == "application/json")
        #expect(sent.timeoutInterval == 42)
    }

    /// The response is handed back untouched, and a transport failure propagates
    /// rather than being swallowed — the consumers' 401-retry, status policies,
    /// and `ConnectivityMonitor` hooks all key on exactly these two outcomes.
    @Test func propagatesTheBaseSessionsResponseAndFailure() async throws {
        let base = StubRequestSession()
        base.enqueue(StubRequestSession.Stub(statusCode: 418, body: Data("teapot".utf8)))
        let session = CookielessSession(base)

        let (data, response) = try await session.data(for: URLRequest(url: Self.url))
        #expect(data == Data("teapot".utf8))
        #expect((response as? HTTPURLResponse)?.statusCode == 418)

        base.enqueue(failure: URLError(.notConnectedToInternet))
        await #expect(throws: URLError.self) {
            _ = try await session.data(for: URLRequest(url: Self.url))
        }
    }
}
