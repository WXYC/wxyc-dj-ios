//
//  APIClientTests.swift
//  WXYCAPITests
//
//  Exercises the production endpoints with stubbed responses: search
//  composes the right query string, /library/info hits the album_id route,
//  POST /djs/bin sends album_id+track_title, and a one-shot 401 forces a
//  JWT refresh and a single retry.
//
//  Created by Jake on 5/14/26.
//  Copyright © 2026 WXYC. All rights reserved.
//

import Foundation
import Testing
@testable import WXYCAPI

@Suite("APIClient", .serialized)
@MainActor
struct APIClientTests {
    private static let config = WXYCAPIConfiguration.localDevelopment

    /// Stand up an AuthService already pinned to .signedIn with a fresh JWT, plus the APIClient under test.
    private static func makeSignedInClient() async throws -> (APIClient, AuthService, StubRequestSession) {
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
        return (client, auth, session)
    }

    @Test func searchLibraryComposesQueryAndAttachesBearer() async throws {
        let (client, _, session) = try await Self.makeSignedInClient()
        session.enqueue(StubRequestSession.Stub(
            statusCode: 200,
            body: Data("[\(Fixtures.juanaMolinaSearchResult)]".utf8)
        ))

        let results = try await client.searchLibrary(artist: "Juana", title: nil, limit: 10)

        #expect(results.count == 1)
        #expect(results.first?.artistName == "Juana Molina")
        let request = try #require(session.recordedRequests.last)
        // URL.appending(path:) may or may not normalize the trailing slash;
        // accept either form so the test pins behavior, not Foundation's
        // path normalization.
        let path = request.url!.path
        #expect(path == "/library" || path == "/library/")
        let query = request.url!.query ?? ""
        #expect(query.contains("artist_name=Juana"))
        #expect(query.contains("n=10"))
        #expect(request.value(forHTTPHeaderField: "Authorization")?.hasPrefix("Bearer ") == true)
    }

    @Test func albumInfoSendsAlbumIdQuery() async throws {
        let (client, _, session) = try await Self.makeSignedInClient()
        session.enqueue(StubRequestSession.Stub(
            statusCode: 200,
            body: Data(Fixtures.albumInfoJSON.utf8)
        ))

        let info = try await client.albumInfo(albumId: 100)

        #expect(info.id == 100)
        let q = session.recordedRequests.last!.url!.query ?? ""
        #expect(q.contains("album_id=100"))
    }

    @Test func addToBinPostsBodyWithAlbumId() async throws {
        let (client, _, session) = try await Self.makeSignedInClient()
        session.enqueue(StubRequestSession.Stub(
            statusCode: 201,
            body: Data(Fixtures.binEntryJSON.utf8)
        ))

        let added = try await client.addToBin(albumId: 200, trackTitle: nil)

        #expect(added.albumId == 200)
        let request = session.recordedRequests.last!
        #expect(request.httpMethod == "POST")
        let body = String(data: request.httpBody ?? Data(), encoding: .utf8) ?? ""
        #expect(body.contains("\"album_id\":200"))
    }

    @Test func removeFromBinSendsDeleteWithQuery() async throws {
        let (client, _, session) = try await Self.makeSignedInClient()
        session.enqueue(StubRequestSession.Stub(statusCode: 200))

        try await client.removeFromBin(albumId: 200, trackTitle: nil)

        let request = session.recordedRequests.last!
        #expect(request.httpMethod == "DELETE")
        #expect(request.url!.query?.contains("album_id=200") == true)
        #expect(request.url!.query?.contains("track_title") == false)
    }

    @Test func removeFromBinIncludesTrackTitleWhenProvided() async throws {
        let (client, _, session) = try await Self.makeSignedInClient()
        session.enqueue(StubRequestSession.Stub(statusCode: 200))

        try await client.removeFromBin(albumId: 200, trackTitle: "la paradoja")

        let request = try #require(session.recordedRequests.last)
        let query = request.url?.query ?? ""
        #expect(query.contains("album_id=200"))
        // URLQueryItem percent-encodes the space.
        #expect(query.contains("track_title=la%20paradoja") || query.contains("track_title=la+paradoja"))
    }

    @Test func unauthorizedTriggersRefreshAndRetry() async throws {
        let (client, _, session) = try await Self.makeSignedInClient()
        // First call: 401, then APIClient refreshes JWT, then call again succeeds.
        session.enqueue(StubRequestSession.Stub(statusCode: 401, body: Data()))
        session.enqueue(StubRequestSession.Stub(
            statusCode: 200,
            body: Data(#"{"token":"\#(Fixtures.jwt())"}"#.utf8)
        ))
        session.enqueue(StubRequestSession.Stub(
            statusCode: 200,
            body: Data("[\(Fixtures.juanaMolinaSearchResult)]".utf8)
        ))

        let results = try await client.searchLibrary(artist: "Juana", title: nil)

        #expect(results.count == 1)
        // restoreSession + 401 + refresh + retry = 4 requests
        #expect(session.recordedRequests.count == 4)
        #expect(Self.isLibraryPath(session.recordedRequests[1].url!.path))
        #expect(session.recordedRequests[2].url!.path == "/auth/token")
        #expect(Self.isLibraryPath(session.recordedRequests[3].url!.path))
    }

    private static func isLibraryPath(_ path: String) -> Bool {
        path == "/library" || path == "/library/"
    }
}
