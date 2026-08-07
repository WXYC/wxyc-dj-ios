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
    private static func makeSignedInClient() async throws -> (APIClient, StubRequestSession) {
        let session = StubRequestSession()
        let storage = InMemoryTokenStorage()
        try storage.save("session-abc", for: .sessionToken)
        let auth = AuthService(configuration: config, storage: storage, session: session)
        session.enqueue(StubRequestSession.Stub(
            statusCode: 200,
            body: Data(#"{"token":"\#(Fixtures.jwt())"}"#.utf8)
        ))
        await auth.restoreSession()
        let client = APIClient(configuration: config, session: session, authService: auth)
        return (client, session)
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
}
