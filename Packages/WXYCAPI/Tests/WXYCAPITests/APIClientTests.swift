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
        // Issue #99: this client wraps its session in `CookielessSession` (which
        // owns the why, and is pinned in `CookielessSessionTests`). Asserted here
        // because the wrap, not the guarantee, is what this consumer can drop.
        #expect(request.httpShouldHandleCookies == false)
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

    /// A `null` body must not read as an empty bin: `BinViewModel` persists what
    /// this returns, and an `[]` would overwrite the offline snapshot with
    /// authoritative emptiness. Fail closed so the last-good bin survives.
    @Test func getBinRejectsANullBodyRatherThanReadingItAsEmpty() async throws {
        let (client, _, session) = try await Self.makeSignedInClient()
        session.enqueue(StubRequestSession.Stub(statusCode: 200, body: Data("null".utf8)))

        await #expect(throws: APIError.self) { try await client.getBin() }
    }

    /// A genuinely empty bin is still authoritative emptiness — the distinction
    /// issue #60's snapshot-present marker exists to carry.
    @Test func getBinDecodesAnEmptyArrayAsAnEmptyBin() async throws {
        let (client, _, session) = try await Self.makeSignedInClient()
        session.enqueue(StubRequestSession.Stub(statusCode: 200, body: Data("[]".utf8)))

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
        #expect(rows.first?.rotationKillDate.day == day("2026-07-01"))
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

    // MARK: - Decoding error detail narrowing (issue #106)

    /// `JSONCoders.decoder`'s custom date strategy builds a `DecodingError
    /// .dataCorrupted` whose `Context.debugDescription` is
    /// `"Unrecognized date format: \(raw)"` -- `raw` being verbatim server
    /// response content. Before the #106 narrowing, `describe(_:)`
    /// interpolated that debugDescription directly into
    /// `APIError.decoding(detail:)`, making it a live channel for whatever
    /// the server sent. The sentinel stands in for something sensitive that
    /// must never survive into the reported detail -- only the case kind and
    /// the coding-key path may.
    @Test func decodingDetailDropsServerContentFromADataCorruptedDate() async throws {
        let (client, _, session) = try await Self.makeSignedInClient()
        session.enqueue(StubRequestSession.Stub(
            statusCode: 200,
            body: Data(#"[{"id":100,"album_title":"DOGA","artist_name":"Juana Molina","add_date":"SECRET_PAYLOAD"}]"#.utf8)
        ))

        do {
            _ = try await client.searchLibrary(artist: "Juana", title: nil)
            Issue.record("expected a decoding failure")
        } catch APIError.decoding(let detail) {
            #expect(!detail.contains("SECRET_PAYLOAD"))
            #expect(detail.contains("data corrupted"))
            #expect(detail.contains("add_date"))
        }
    }

    /// The `.typeMismatch` arm interpolated `Context.debugDescription` too --
    /// Foundation's own wording ("Expected to decode Int but found a string
    /// instead"), not server content -- but the narrowing drops it
    /// regardless: the formatter is code-derived by construction, not
    /// "server content only", so a future arm can't reintroduce the same
    /// hazard by reasoning "this debugDescription is safe." It DOES still
    /// carry the expected `Any.Type` (issue #106 review Fix 4b) -- code-
    /// derived from the model's declared property type, never from the
    /// payload, so it restores most of what `debugDescription` gave issue
    /// #77's original triage without reopening the channel.
    @Test func decodingDetailDropsDebugDescriptionFromATypeMismatch() async throws {
        let (client, _, session) = try await Self.makeSignedInClient()
        session.enqueue(StubRequestSession.Stub(
            statusCode: 200,
            body: Data(#"[{"id":"not-an-int","album_title":"DOGA","artist_name":"Juana Molina"}]"#.utf8)
        ))

        do {
            _ = try await client.searchLibrary(artist: "Juana", title: nil)
            Issue.record("expected a decoding failure")
        } catch APIError.decoding(let detail) {
            #expect(!detail.contains("Expected to decode"))
            #expect(detail.contains("type mismatch"))
            #expect(detail.contains("id"))
            #expect(detail.contains("expected Int"))
        }
    }

    /// `.valueNotFound` -- a key present on the wire with an explicit `null`
    /// against a non-optional model field -- gets the same expected-type
    /// treatment as `.typeMismatch` (issue #106 review Fix 4b).
    @Test func decodingDetailIncludesTheExpectedTypeOnAValueNotFound() async throws {
        let (client, _, session) = try await Self.makeSignedInClient()
        session.enqueue(StubRequestSession.Stub(
            statusCode: 200,
            body: Data(#"[{"id":100,"album_title":null,"artist_name":"Juana Molina"}]"#.utf8)
        ))

        do {
            _ = try await client.searchLibrary(artist: "Juana", title: nil)
            Issue.record("expected a decoding failure")
        } catch APIError.decoding(let detail) {
            #expect(detail.contains("album_title"))
            #expect(detail.contains("expected non-null String"))
        }
    }

    /// `.keyNotFound` never carried `debugDescription` even before the
    /// narrowing -- pinned here so the case-kind + coding-path shape is
    /// covered for all three data-bearing cases, not just the two that
    /// changed.
    @Test func decodingDetailReportsTheMissingKeyAndPath() async throws {
        let (client, _, session) = try await Self.makeSignedInClient()
        // artist_name is required; omitting it triggers .keyNotFound.
        session.enqueue(StubRequestSession.Stub(
            statusCode: 200,
            body: Data(#"[{"id":100,"album_title":"DOGA"}]"#.utf8)
        ))

        do {
            _ = try await client.searchLibrary(artist: "Juana", title: nil)
            Issue.record("expected a decoding failure")
        } catch APIError.decoding(let detail) {
            #expect(detail.contains("artist_name"))
        }
    }

    // Note: DecodingError has exactly four cases today (keyNotFound,
    // typeMismatch, valueNotFound, dataCorrupted), all handled explicitly
    // above -- there is no way to construct a fifth through normal decoding,
    // so the `@unknown default:` arm's constant string isn't reachable from
    // a test. It's covered by inspection instead: see the doc comment on
    // `APIClient.describe(_:)`.

    // MARK: - Offline vs. network classification (issue #106 review Fix 1)

    /// A connectivity-class transport failure -- the link failed, not the
    /// request -- flattens to `.offline` at `fire(_:)`'s catch-all, not
    /// `.network`. This is the split the reporting sites (`AppDependencies`,
    /// `BinViewModel`) key on to skip an offline DJ; a regression here would
    /// silently reopen the event-spam bug those sites were fixed to close.
    @Test func connectivityClassTransportFailureThrowsOffline() async throws {
        let (client, session, recorder) = try await Self.makeSignedInClientWithRecorder()
        session.enqueue(failure: URLError(.notConnectedToInternet))

        do {
            _ = try await client.searchLibrary(artist: "Juana", title: nil)
            Issue.record("expected a thrown error")
        } catch APIError.offline {
            // pass
        } catch {
            Issue.record("expected .offline, got \(error)")
        }
        #expect(recorder.values == [false])
    }

    /// A resource/request-level `URLError` -- not a link failure --
    /// deliberately stays `.network`: `ConnectivityErrorClassification`
    /// excludes `.cannotDecodeContentData` on purpose (it's what a CDN
    /// error page looks like by the time it reaches a decoder, not evidence
    /// of being offline), so this is a genuine defect worth reporting.
    @Test func nonConnectivityTransportFailureThrowsNetwork() async throws {
        let (client, session, recorder) = try await Self.makeSignedInClientWithRecorder()
        session.enqueue(failure: URLError(.cannotDecodeContentData))

        do {
            _ = try await client.searchLibrary(artist: "Juana", title: nil)
            Issue.record("expected a thrown error")
        } catch APIError.network {
            // pass
        } catch {
            Issue.record("expected .network, got \(error)")
        }
        #expect(recorder.values == [false])
    }

    /// A cancelled request throws `.offline`, not `.network` -- a routine
    /// navigate-away (the issue-#58 debounce, a DJ backing out of a detail
    /// screen) must not read as a defect (issue #106 review Fix 1/2). The
    /// pre-existing cancellation carve-out for `ConnectivityMonitor` is
    /// unaffected: still no `onOutcome` call either way.
    @Test func cancelledRequestThrowsOfflineWithoutTouchingConnectivity() async throws {
        let (client, session, recorder) = try await Self.makeSignedInClientWithRecorder()
        session.enqueue(failure: URLError(.cancelled))

        do {
            _ = try await client.searchLibrary(artist: "Juana", title: nil)
            Issue.record("expected a thrown error")
        } catch APIError.offline {
            // pass
        } catch {
            Issue.record("expected .offline, got \(error)")
        }
        #expect(recorder.values.isEmpty)
    }

    /// Same rationale as above for structured-concurrency cancellation
    /// surfaced as `CancellationError` rather than `URLError(.cancelled)` --
    /// not itself a `URLError`, so `classifyTransportFailure` can't classify
    /// it by code, but it is unconditionally `.offline` regardless.
    @Test func structuredCancellationThrowsOfflineWithoutTouchingConnectivity() async throws {
        let (client, session, recorder) = try await Self.makeSignedInClientWithRecorder()
        session.enqueue(failure: CancellationError())

        do {
            _ = try await client.searchLibrary(artist: "Juana", title: nil)
            Issue.record("expected a thrown error")
        } catch APIError.offline {
            // pass
        } catch {
            Issue.record("expected .offline, got \(error)")
        }
        #expect(recorder.values.isEmpty)
    }

    /// The second flatten site: `AuthService.currentJWT()` rethrows a raw,
    /// unwrapped transport error (not an `AuthError`) when the lazy
    /// JWT-refresh leg itself fails offline (see `AuthService.send(_:)`).
    /// `APIClient.currentJWT()`'s catch-all has to classify it exactly like
    /// `fire(_:)` does, or this second discard site reopens the same bug one
    /// layer down -- a DJ whose cached JWT expired while offline would file
    /// a Sentry event on every request attempt.
    @Test func currentJWTTransportFailureDuringLazyRefreshThrowsOffline() async throws {
        let session = StubRequestSession()
        let storage = InMemoryTokenStorage()
        try storage.save("session-abc", for: .sessionToken)
        let auth = AuthService(configuration: Self.config, storage: storage, session: session)
        // restoreSession()'s JWT exchange fails offline -> the issue-#53
        // pending window (.signedIn(payload: nil)), no cached JWT yet.
        session.enqueue(failure: URLError(.notConnectedToInternet))
        await auth.restoreSession()

        let client = APIClient(configuration: Self.config, session: session, authService: auth)
        // The lazy JWT refresh APIClient.perform() triggers also fails offline.
        session.enqueue(failure: URLError(.notConnectedToInternet))

        do {
            _ = try await client.searchLibrary(artist: "Juana", title: nil)
            Issue.record("expected a thrown error")
        } catch APIError.offline {
            // pass
        } catch {
            Issue.record("expected .offline, got \(error)")
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
