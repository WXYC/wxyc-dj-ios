//
//  APIClientTests.swift
//  WXYCAPITests
//
//  Exercises the production endpoints with stubbed responses: search
//  composes the right query string, /library/info hits the album_id route,
//  POST /djs/bin sends album_id+track_title, a one-shot 401 forces a
//  JWT refresh and a single retry, and GET /library/catalog round-trips the
//  conditional-GET NDJSON export (If-Modified-Since out, Last-Modified in, 304
//  as a not-modified sentinel).
//
//  Created by Jake on 5/14/26.
//  Copyright © 2026 WXYC. All rights reserved.
//

import Foundation
import os
import Testing
@testable import WXYCAPI

@Suite("APIClient", .serialized)
@MainActor
struct APIClientTests {
    private static let config = WXYCAPIConfiguration.localDevelopment

    /// Thread-safe sink for the `APIClient` outcome hook (#56): records each
    /// `true`/`false` transport result in order. `Sendable` (lock-backed) so it
    /// can be captured in the `@Sendable` outcome closure.
    private final class OutcomeRecorder: Sendable {
        private let storage = OSAllocatedUnfairLock<[Bool]>(initialState: [])
        var values: [Bool] { storage.withLock { $0 } }
        func record(_ success: Bool) { storage.withLock { $0.append(success) } }
    }

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

    /// Like ``makeSignedInClient()`` but wires the outcome hook to a recorder so
    /// the connectivity correction (#56) can be asserted. The session-token
    /// restore runs through `AuthService`, not `APIClient.fire`, so it never
    /// pollutes the recorder.
    private static func makeSignedInClientWithRecorder() async throws -> (APIClient, StubRequestSession, OutcomeRecorder) {
        let session = StubRequestSession()
        let storage = InMemoryTokenStorage()
        try storage.save("session-abc", for: .sessionToken)
        let auth = AuthService(configuration: config, storage: storage, session: session)
        session.enqueue(StubRequestSession.Stub(
            statusCode: 200,
            body: Data(#"{"token":"\#(Fixtures.jwt())"}"#.utf8)
        ))
        await auth.restoreSession()
        let recorder = OutcomeRecorder()
        let client = APIClient(
            configuration: config,
            session: session,
            authService: auth,
            onOutcome: { recorder.record($0) }
        )
        return (client, session, recorder)
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

    @Test func getBinDecodesTheBareArrayResponse() async throws {
        let (client, _, session) = try await Self.makeSignedInClient()
        session.enqueue(StubRequestSession.Stub(
            statusCode: 200,
            body: Data(Fixtures.binResponseJSON.utf8)
        ))

        let entries = try await client.getBin()

        #expect(entries.count == 2)
        #expect(Set(entries.map(\.albumId)) == [100, 200])
        #expect(session.recordedRequests.last?.url?.path == "/djs/bin")
    }

    @Test func getBinTreatsANullBodyAsAnEmptyBin() async throws {
        let (client, _, session) = try await Self.makeSignedInClient()
        session.enqueue(StubRequestSession.Stub(statusCode: 200, body: Data("null".utf8)))

        #expect(try await client.getBin().isEmpty)
    }

    @Test func addToBinPostsBodyWithAlbumId() async throws {
        let (client, _, session) = try await Self.makeSignedInClient()
        // The 201 body is the raw `bins` row, which the client never decodes —
        // enqueued here to prove that shape can't fail the call.
        session.enqueue(StubRequestSession.Stub(
            statusCode: 201,
            body: Data(Fixtures.addToBinResponseJSON.utf8)
        ))

        try await client.addToBin(albumId: 200, trackTitle: nil)

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

    // MARK: - GET /library/catalog (conditional-GET NDJSON export, issue #19)

    @Test func catalogDecodesNdjsonRowsCapturesLastModifiedAndSendsIfModifiedSince() async throws {
        let (client, _, session) = try await Self.makeSignedInClient()
        let priorWatermark = "Sun, 21 Jun 2026 00:00:00 GMT"
        let newWatermark = "Mon, 22 Jun 2026 17:00:00 GMT"
        session.enqueue(StubRequestSession.Stub(
            statusCode: 200,
            headers: ["Last-Modified": newWatermark, "Content-Type": "application/x-ndjson"],
            body: Data(Fixtures.catalogNDJSON.utf8)
        ))

        let result = try await client.catalog(ifModifiedSince: priorWatermark)

        guard case let .modified(rows, lastModified) = result else {
            Issue.record("expected .modified, got \(result)")
            return
        }
        #expect(rows.count == 2)
        #expect(rows.first?.id == 100)
        #expect(rows.first?.artistName == "Juana Molina")
        #expect(rows.first?.rotationKillDate == "2026-07-01")
        // Row 2's optionals are null on the wire — the lenient decode keeps the row.
        #expect(rows.last?.id == 200)
        #expect(rows.last?.rotationBin == nil)
        #expect(rows.last?.artworkURL == nil)
        // The new watermark is captured verbatim, not round-tripped through Date.
        #expect(lastModified == newWatermark)

        let request = try #require(session.recordedRequests.last)
        #expect(request.url?.path == "/library/catalog")
        #expect(request.httpMethod == "GET")
        #expect(request.value(forHTTPHeaderField: "If-Modified-Since") == priorWatermark)
    }

    @Test func catalogNotModifiedReturnsSentinelNotError() async throws {
        let (client, _, session) = try await Self.makeSignedInClient()
        // 304: the middleware short-circuits with no body and no Last-Modified.
        session.enqueue(StubRequestSession.Stub(statusCode: 304))

        let result = try await client.catalog(ifModifiedSince: "Sun, 21 Jun 2026 00:00:00 GMT")

        #expect(result == .notModified)
    }

    @Test func catalogFirstFetchOmitsIfModifiedSinceWhenWatermarkIsNil() async throws {
        let (client, _, session) = try await Self.makeSignedInClient()
        session.enqueue(StubRequestSession.Stub(
            statusCode: 200,
            headers: ["Last-Modified": "Mon, 22 Jun 2026 17:00:00 GMT"],
            body: Data(Fixtures.catalogNDJSON.utf8)
        ))

        _ = try await client.catalog(ifModifiedSince: nil)

        let request = try #require(session.recordedRequests.last)
        #expect(request.value(forHTTPHeaderField: "If-Modified-Since") == nil)
    }

    @Test func catalogEmptyBodyDecodesToZeroRows() async throws {
        let (client, _, session) = try await Self.makeSignedInClient()
        // serializeCatalogNdjson([]) === "" — an empty catalog is a 200 with an
        // empty body, which must decode to zero rows rather than throw.
        session.enqueue(StubRequestSession.Stub(
            statusCode: 200,
            headers: ["Last-Modified": "Mon, 22 Jun 2026 17:00:00 GMT"],
            body: Data()
        ))

        let result = try await client.catalog(ifModifiedSince: nil)

        guard case let .modified(rows, _) = result else {
            Issue.record("expected .modified, got \(result)")
            return
        }
        #expect(rows.isEmpty)
    }

    @Test func catalogUnauthorizedRefreshesAndRetriesWithConditionalHeader() async throws {
        let (client, _, session) = try await Self.makeSignedInClient()
        let watermark = "Sun, 21 Jun 2026 00:00:00 GMT"
        session.enqueue(StubRequestSession.Stub(statusCode: 401, body: Data()))
        session.enqueue(StubRequestSession.Stub(
            statusCode: 200,
            body: Data(#"{"token":"\#(Fixtures.jwt())"}"#.utf8)
        ))
        session.enqueue(StubRequestSession.Stub(
            statusCode: 200,
            headers: ["Last-Modified": "Mon, 22 Jun 2026 17:00:00 GMT"],
            body: Data(Fixtures.catalogNDJSON.utf8)
        ))

        let result = try await client.catalog(ifModifiedSince: watermark)

        guard case let .modified(rows, _) = result else {
            Issue.record("expected .modified after retry, got \(result)")
            return
        }
        #expect(rows.count == 2)
        // restoreSession + 401 + refresh + retry = 4 requests
        #expect(session.recordedRequests.count == 4)
        #expect(session.recordedRequests[2].url?.path == "/auth/token")
        // The retried catalog request still carries the conditional header.
        #expect(session.recordedRequests.last?.value(forHTTPHeaderField: "If-Modified-Since") == watermark)
    }

    @Test func catalogSkipsBlankAndWhitespaceLines() async throws {
        let (client, _, session) = try await Self.makeSignedInClient()
        // A leading blank line, a whitespace-only separator, and a trailing
        // newline are not records — they must be skipped, not decoded, so every
        // real row survives. (serializeCatalogNdjson never emits these, but the
        // parser must not fail the whole fetch if any intermediary introduces one.)
        let body = "\n" + Fixtures.catalogNDJSON.replacingOccurrences(of: "\n", with: "\n \n") + "\n"
        session.enqueue(StubRequestSession.Stub(statusCode: 200, body: Data(body.utf8)))

        let result = try await client.catalog(ifModifiedSince: nil)

        guard case let .modified(rows, _) = result else {
            Issue.record("expected .modified, got \(result)")
            return
        }
        #expect(rows.count == 2)
        #expect(rows.first?.id == 100)
        #expect(rows.last?.id == 200)
    }

    @Test func catalogToleratesBlankLineUnderCRLF() async throws {
        let (client, _, session) = try await Self.makeSignedInClient()
        // A blank line under CRLF endings (`...\r\n\r\nrow2...`) splits on \n into
        // a lone-`\r` chunk BETWEEN records — non-empty, so the old
        // `omittingEmptySubsequences: true` path kept it and fed `\r` to
        // JSONDecoder, failing the whole fetch. Both real rows must still survive.
        // (Discriminating: an interior blank line, not just a trailing one a
        // simple split would drop.)
        let body = Fixtures.catalogNDJSON.replacingOccurrences(of: "\n", with: "\r\n\r\n") + "\r\n"
        session.enqueue(StubRequestSession.Stub(statusCode: 200, body: Data(body.utf8)))

        let result = try await client.catalog(ifModifiedSince: nil)

        guard case let .modified(rows, _) = result else {
            Issue.record("expected .modified, got \(result)")
            return
        }
        #expect(rows.count == 2)
        #expect(rows.first?.id == 100)
        #expect(rows.last?.id == 200)
    }

    @Test func catalogMalformedLineThrowsDecodingError() async throws {
        let (client, _, session) = try await Self.makeSignedInClient()
        // A line with real content that isn't valid JSON fails the whole fetch
        // (the caller keeps its last-good clone) — distinct from a blank line,
        // which is skipped. The malformed record is the 3rd physical line.
        let body = "\(Fixtures.catalogNDJSON)\n{not valid json"
        session.enqueue(StubRequestSession.Stub(statusCode: 200, body: Data(body.utf8)))

        do {
            _ = try await client.catalog(ifModifiedSince: nil)
            Issue.record("expected catalog() to throw on a malformed NDJSON line")
        } catch APIError.decoding(let detail) {
            #expect(detail.contains("NDJSON line 3"))
        }
    }

    @Test func catalogServerErrorSurfacesAsHTTPError() async throws {
        let (client, _, session) = try await Self.makeSignedInClient()
        session.enqueue(StubRequestSession.Stub(
            statusCode: 500,
            body: Data(#"{"message":"boom"}"#.utf8)
        ))

        do {
            _ = try await client.catalog(ifModifiedSince: nil)
            Issue.record("expected catalog() to throw on a 500")
        } catch APIError.http(let status, let message) {
            #expect(status == 500)
            #expect(message == "boom")
        }
    }

    @Test func catalogNon200SuccessIsNotTreatedAsEmptyCatalog() async throws {
        let (client, _, session) = try await Self.makeSignedInClient()
        // A non-200 2xx (e.g. 204) must surface as an error rather than decode to
        // zero rows — treating it as an empty catalog would wipe the on-device clone.
        session.enqueue(StubRequestSession.Stub(statusCode: 204))

        do {
            _ = try await client.catalog(ifModifiedSince: nil)
            Issue.record("expected catalog() to throw on a 204")
        } catch APIError.http(let status, _) {
            #expect(status == 204)
        }
    }

    @Test func catalogEmptyStringWatermarkOmitsIfModifiedSince() async throws {
        let (client, _, session) = try await Self.makeSignedInClient()
        session.enqueue(StubRequestSession.Stub(
            statusCode: 200,
            headers: ["Last-Modified": "Mon, 22 Jun 2026 17:00:00 GMT"],
            body: Data(Fixtures.catalogNDJSON.utf8)
        ))

        // An empty string is a cleared/absent watermark — it must not emit a
        // malformed `If-Modified-Since: ` header.
        _ = try await client.catalog(ifModifiedSince: "")

        let request = try #require(session.recordedRequests.last)
        #expect(request.value(forHTTPHeaderField: "If-Modified-Since") == nil)
    }

    @Test func catalogModifiedWithoutLastModifiedHeaderYieldsNilWatermark() async throws {
        let (client, _, session) = try await Self.makeSignedInClient()
        // A 200 with no Last-Modified header yields lastModified == nil (the
        // documented contract) rather than a synthesized/default watermark.
        session.enqueue(StubRequestSession.Stub(
            statusCode: 200,
            body: Data(Fixtures.catalogNDJSON.utf8)
        ))

        let result = try await client.catalog(ifModifiedSince: "Sun, 21 Jun 2026 00:00:00 GMT")

        guard case let .modified(rows, lastModified) = result else {
            Issue.record("expected .modified, got \(result)")
            return
        }
        #expect(rows.count == 2)
        #expect(lastModified == nil)
    }

    // MARK: - Connectivity outcome hook (#56)

    @Test func outcomeHookReportsSuccessWhenServerAnswers() async throws {
        let (client, session, recorder) = try await Self.makeSignedInClientWithRecorder()
        session.enqueue(StubRequestSession.Stub(
            statusCode: 200,
            body: Data("[\(Fixtures.juanaMolinaSearchResult)]".utf8)
        ))

        _ = try await client.searchLibrary(artist: "Juana", title: nil)

        #expect(recorder.values == [true])
    }

    @Test func outcomeHookReportsSuccessEvenOnServerErrorStatus() async throws {
        // A 500 still means we *reached* the server — connectivity is up — so the
        // hook reports success even though the call throws .http.
        let (client, session, recorder) = try await Self.makeSignedInClientWithRecorder()
        session.enqueue(StubRequestSession.Stub(
            statusCode: 500,
            body: Data(#"{"message":"boom"}"#.utf8)
        ))

        await #expect(throws: APIError.self) {
            _ = try await client.searchLibrary(artist: "Juana", title: nil)
        }

        #expect(recorder.values == [true])
    }

    @Test func outcomeHookReportsFailureOnTransportError() async throws {
        let (client, session, recorder) = try await Self.makeSignedInClientWithRecorder()
        // The transport throws before any response — the offline signal.
        session.enqueue(failure: URLError(.notConnectedToInternet))

        await #expect(throws: APIError.self) {
            _ = try await client.searchLibrary(artist: "Juana", title: nil)
        }

        #expect(recorder.values == [false])
    }

    @Test func outcomeHookIgnoresCancelledRequest() async throws {
        // A cancelled request is *not* a connectivity signal — it means the
        // caller superseded the call (the issue-#58 search debounce cancels the
        // in-flight task on every keystroke), not that the server was
        // unreachable. Latching offline here would wrongly route later searches
        // to the local clone while the device is actually online, with no
        // self-recovery (a local search makes no request, so no later success
        // restores the flag). The call still throws so the caller bails.
        let (client, session, recorder) = try await Self.makeSignedInClientWithRecorder()
        session.enqueue(failure: URLError(.cancelled))

        await #expect(throws: APIError.self) {
            _ = try await client.searchLibrary(artist: "Juana", title: nil)
        }

        #expect(recorder.values.isEmpty)
    }

    @Test func outcomeHookIgnoresCancellationError() async throws {
        // Same rationale as the URLError(.cancelled) case, for a RequestSession
        // that surfaces structured-concurrency cancellation as CancellationError.
        let (client, session, recorder) = try await Self.makeSignedInClientWithRecorder()
        session.enqueue(failure: CancellationError())

        await #expect(throws: APIError.self) {
            _ = try await client.searchLibrary(artist: "Juana", title: nil)
        }

        #expect(recorder.values.isEmpty)
    }
}
