//
//  APIClient.swift
//  WXYCAPI
//
//  Thin URLSession wrapper that hits Backend-Service routes. Calls
//  AuthService.currentJWT() to attach a Bearer token, retries once on a 401
//  (which forces a JWT refresh), and exposes typed methods for the endpoints
//  the DJ tool consumes: library search, /library/info, /proxy/metadata/album,
//  GET/POST/DELETE /djs/bin, and the conditional-GET /library/catalog bulk
//  export (issue #19).
//
//  Created by Jake on 5/14/26.
//  Copyright © 2026 WXYC. All rights reserved.
//

import Foundation

public enum APIError: Error, Sendable {
    case unauthorized
    case notSignedIn
    case http(status: Int, message: String?)
    case decoding(detail: String)
    case network(String)
    /// A connectivity-class transport failure (no route to the server, DNS,
    /// timeout, captive portal, or a deliberate cancellation -- see
    /// ``ConnectivityErrorClassification``), discovered at one of this
    /// package's flatten sites that used to fold every non-`APIError` throw
    /// into ``network(_:)`` unconditionally: ``APIClient/fire(_:)``'s
    /// catch-all, and ``APIClient/currentJWT()``'s -- the lazy JWT-refresh
    /// leg can itself fail offline one layer below `fire`, since
    /// `AuthService.currentJWT()` rethrows a raw, unwrapped transport error
    /// on that specific leg rather than an `AuthError` (see
    /// `AuthService.send(_:)`), so a second discard site existed here that
    /// mirrored `fire`'s exactly.
    ///
    /// Being offline is a supported mode -- the app has an on-device catalog
    /// clone and falls back to it (issues #58/#81) -- and is never worth
    /// reporting to crash telemetry, unlike a genuine transport defect
    /// (issue #106). **`.cancelled` is deliberately included in the
    /// connectivity classification, not an oversight left to work around:**
    /// neither a genuinely offline request nor a cancelled one is a defect,
    /// so both belong in the non-reported bucket. The debounced search in
    /// `LibrarySearch` (issue #58) and a DJ backing out of
    /// `AlbumDetailView` before `/library/info` returns both cancel an
    /// in-flight request on every routine interaction -- reporting either as
    /// a defect would be exactly the event spam `enableCaptureFailedRequests
    /// = false` exists to prevent, just reached through cancellation instead
    /// of a captive portal. This is this enum's peer to
    /// ``AuthError/offline(message:)``, added because the API path had the
    /// identical flatten-and-discard shape without the split.
    ///
    /// Carries the same message ``network(_:)`` would have, so
    /// ``localizedMessage`` renders byte-for-byte what a caller saw before
    /// this split existed -- the split changes only which *case* a caller
    /// pattern matches on to decide whether to report, never what's shown on
    /// screen.
    case offline(message: String)

    public var localizedMessage: String {
        switch self {
        case .unauthorized: "Your session expired. Please sign in again."
        case .notSignedIn: "Please sign in."
        case .http(let s, let m): "Server error (\(s))\(m.map { ": \($0)" } ?? "")."
        case .decoding(let detail): "The server returned an unexpected response: \(detail)"
        case .network(let m): "Network error: \(m)"
        case .offline(let m): "Network error: \(m)"
        }
    }
}

extension APIError {
    /// A case-identifying value safe to attach to a crash report — mirrors
    /// ``AuthError/CaseName`` (issue #106) for this package's other error
    /// enum. `.http(status:message:)`'s server-authored `message` and
    /// `.network(String)`'s / `.offline(message:)`'s client-side
    /// description are dropped by construction; the case name, `.http`'s
    /// status as a plain `Int`, and `.decoding(detail:)`'s narrowed `detail`
    /// string are what survive.
    ///
    /// `.decoding(detail:)`'s `detail` is the **one** deliberate exception to
    /// "never carry an associated string," and it is safe only because two
    /// facts are load-bearing on each other. `CaseName` itself carries
    /// nothing but whatever the case already held — the actual narrowing
    /// happens one level up, in ``APIClient/describe(_:)``, which is
    /// deliberately restricted to code-derived facts alone (the
    /// `DecodingError` case kind, the coding-key path, and the expected
    /// `Any.Type` on a type mismatch) and never `Context.debugDescription`,
    /// a live channel for verbatim server response content. That function's
    /// own regression tests (`APIClientTests`) pin that it can emit nothing
    /// else. Carrying `detail` here would reopen the "never report
    /// server-sent text" rule the moment that formatter regressed — it
    /// stays honest only as long as that guarantee holds.
    ///
    /// Implemented as an exhaustive `switch` with **no `default:`**: adding a
    /// case to `APIError` without extending this switch is a compile error,
    /// not a silent gap.
    public struct CaseName: Sendable, Equatable {
        public let name: String
        public let statusCode: Int?
        /// `.decoding(detail:)`'s narrowed detail string, present only for
        /// that case — see this type's doc comment for why carrying it here
        /// is safe. `nil` for every other case.
        public let detail: String?
    }

    public var caseName: CaseName {
        switch self {
        case .unauthorized:
            CaseName(name: "unauthorized", statusCode: nil, detail: nil)
        case .notSignedIn:
            CaseName(name: "notSignedIn", statusCode: nil, detail: nil)
        case .http(let status, _):
            CaseName(name: "http", statusCode: status, detail: nil)
        case .decoding(let detail):
            CaseName(name: "decoding", statusCode: nil, detail: detail)
        case .network:
            CaseName(name: "network", statusCode: nil, detail: nil)
        case .offline:
            CaseName(name: "offline", statusCode: nil, detail: nil)
        }
    }
}

/// Outcome of a conditional `GET /library/catalog`. Either the catalog is
/// unchanged since the supplied watermark (a cheap `304`), or the server
/// returned the full body plus a fresh `Last-Modified` watermark to persist.
public enum CatalogFetchResult: Equatable, Sendable {
    /// `304 Not Modified` — the catalog has not changed since the
    /// `If-Modified-Since` watermark. No rows, no re-index; keep the stored clone.
    case notModified
    /// `200 OK` — the full catalog. `rows` is the freshly-decoded export;
    /// `lastModified` is the server's new `Last-Modified` HTTP-date string to
    /// store verbatim and echo back next time (`nil` only if the server omitted
    /// the header).
    case modified(rows: [CatalogRow], lastModified: String?)
}

public final class APIClient: Sendable {
    private let configuration: WXYCAPIConfiguration
    /// Deliberately typed as the decorator, not `any RequestSession`: it makes
    /// `self.session = session` fail to compile, so the no-cookie policy can't be
    /// dropped by a consumer that copies this shape (issue #99).
    private let session: CookielessSession
    private let authService: AuthService
    /// Reports each request's transport result to the connectivity layer (#56):
    /// `true` when the server answered (any HTTP status — we reached it), `false`
    /// on a thrown transport error. `nil` outside the app (e.g. unit tests that
    /// don't observe connectivity). Kept actor-free here; `AppDependencies`
    /// supplies a closure that hops to `ConnectivityMonitor` on the main actor.
    private let onOutcome: (@Sendable (Bool) -> Void)?

    public init(
        configuration: WXYCAPIConfiguration,
        session: any RequestSession = URLSession.shared,
        authService: AuthService,
        onOutcome: (@Sendable (Bool) -> Void)? = nil
    ) {
        self.configuration = configuration
        self.session = CookielessSession(session)
        self.authService = authService
        self.onOutcome = onOutcome
    }

    public func searchLibrary(artist: String?, title: String?, limit: Int = 25) async throws -> [AlbumSearchResult] {
        var items: [URLQueryItem] = []
        if let artist, !artist.isEmpty { items.append(URLQueryItem(name: "artist_name", value: artist)) }
        if let title, !title.isEmpty { items.append(URLQueryItem(name: "album_title", value: title)) }
        items.append(URLQueryItem(name: "n", value: String(limit)))
        return try await getJSON("/library/", query: items)
    }

    public func albumInfo(albumId: Int) async throws -> AlbumInfo {
        try await getJSON("/library/info", query: [URLQueryItem(name: "album_id", value: String(albumId))])
    }

    /// GET /digital-archive/albums/{id}/playback (#417) — the archive player's
    /// playback manifest for `albumId`. A 404 (no bound digital audio) surfaces
    /// as `APIError.http(status: 404, ...)`, same `.http` classification
    /// `loadMetadata` already treats as routine, for the view to render "no
    /// audio" rather than an error.
    ///
    /// Every rendition `url` is a bearer credential until the manifest's
    /// `expires_at` — the merged operation states the cache/logging posture
    /// explicitly. This method must never let that URL reach `os_log` or be
    /// embedded in an `NSError` `userInfo`; it decodes the manifest and hands it
    /// straight back, nothing more.
    public func albumPlayback(albumId: Int) async throws -> DigitalArchivePlaybackManifest {
        try await getJSON("/digital-archive/albums/\(albumId)/playback", query: [])
    }

    /// GET /proxy/metadata/album — LML-enriched release record: year, label,
    /// genres/styles, streaming URLs, tracklist, Discogs/Wikipedia URLs.
    public func albumMetadata(artistName: String, releaseTitle: String?, trackTitle: String? = nil) async throws -> AlbumMetadata {
        var items: [URLQueryItem] = [URLQueryItem(name: "artistName", value: artistName)]
        if let releaseTitle, !releaseTitle.isEmpty {
            items.append(URLQueryItem(name: "releaseTitle", value: releaseTitle))
        }
        if let trackTitle, !trackTitle.isEmpty {
            items.append(URLQueryItem(name: "trackTitle", value: trackTitle))
        }
        return try await getJSON("/proxy/metadata/album", query: items)
    }

    /// GET /library/catalog — the full catalog bulk export (BS#1468) the
    /// on-device Spotlight clone mirrors. Conditional GET: pass the
    /// `Last-Modified` string from the previous successful fetch as
    /// `ifModifiedSince` and the server replies `.notModified` (HTTP `304`)
    /// until the catalog actually changes (~daily); otherwise `.modified` with
    /// the decoded rows and the new `Last-Modified` watermark to persist.
    ///
    /// The body is gzipped NDJSON — one ``CatalogRow`` per line, **not** a JSON
    /// array; `URLSession` inflates the gzip transparently (don't set
    /// `Accept-Encoding` by hand). Echo `ifModifiedSince` verbatim — it's the
    /// server's HTTP-date string; never round-trip it through `Date`. Preserves
    /// the standard `401` → JWT-refresh → single-retry behavior.
    public func catalog(ifModifiedSince: String? = nil) async throws -> CatalogFetchResult {
        var headers: [String: String] = [:]
        if let ifModifiedSince, !ifModifiedSince.isEmpty {
            headers["If-Modified-Since"] = ifModifiedSince
        }
        let (data, http) = try await perform(
            path: "/library/catalog",
            method: "GET",
            query: [],
            body: nil,
            extraHeaders: headers
        )
        switch http.statusCode {
        case 304:
            return .notModified
        case 200:
            return .modified(
                rows: try Self.decodeNDJSON(data),
                lastModified: http.value(forHTTPHeaderField: "Last-Modified")
            )
        default:
            // Only `200` (full body) and `304` (not modified) are part of the
            // contract; anything else — including a stray non-200 2xx — is an
            // error, NOT an empty catalog. Matching `200..<300` here would let a
            // `204 No Content` decode to zero rows and wipe the on-device clone.
            throw Self.httpError(status: http.statusCode, body: data)
        }
    }

    /// The DJ's bin, newest server truth. The response is a **bare array** of
    /// denormalized library rows (api.yaml `BinLibraryDetails`), not an
    /// envelope object — the DJ is identified by the bearer token, so nothing
    /// wraps it.
    ///
    /// `[]` and `null` are **not** the same answer here, and the asymmetry is
    /// deliberate:
    ///
    /// - `[]` is a real, authoritative empty bin — a normal state a DJ reaches
    ///   by removing their last release. It decodes, and `BinViewModel`
    ///   persists it as written-empty (issue #60's written-empty vs.
    ///   never-written distinction).
    /// - `null` is not a bin at all, so it fails to decode and throws. dj-site
    ///   coerces it (`BinLibraryDetails[] | null`); we must not, because
    ///   `BinViewModel` persists whatever this returns and `[]` sets the
    ///   store's snapshot-present marker — a coerced `null` would overwrite the
    ///   DJ's last-good offline bin with authoritative emptiness, reading "Bin
    ///   is empty" across cold launches until a real refresh landed. dj-site
    ///   has no offline snapshot to lose; we do.
    ///
    /// Throwing hands the decision to `BinViewModel.handleRefreshFailure`,
    /// which keeps the last good snapshot on screen — that, not anything here,
    /// is the structural analog of `CatalogRefreshService`'s
    /// `.skippedEmptyExport`. Note the catalog's *policy* is the *opposite* of
    /// the bin's: an empty catalog export is treated as a backend hiccup and
    /// refused, because an empty catalog is never legitimate — whereas an empty
    /// bin is. Don't unify them.
    public func getBin() async throws -> [BinEntry] {
        try await getJSON("/djs/bin", query: [])
    }

    /// Add a release to the signed-in DJ's bin. The `201` body is the raw
    /// inserted `bins` row (`id` / `dj_id` / `album_id` / `track_title`) — not
    /// a bin entry, and not something any caller needs — so it's deliberately
    /// left undecoded; the 2xx is the acknowledgement.
    public func addToBin(albumId: Int, trackTitle: String? = nil) async throws {
        let body = try JSONCoders.encoder.encode(AddToBinRequest(albumId: albumId, trackTitle: trackTitle))
        _ = try await sendRaw(path: "/djs/bin", method: "POST", query: [], body: body)
    }

    public func removeFromBin(albumId: Int, trackTitle: String? = nil) async throws {
        var items = [URLQueryItem(name: "album_id", value: String(albumId))]
        if let trackTitle { items.append(URLQueryItem(name: "track_title", value: trackTitle)) }
        _ = try await sendRaw(path: "/djs/bin", method: "DELETE", query: items, body: nil)
    }

    private func getJSON<T: Decodable>(_ path: String, query: [URLQueryItem]) async throws -> T {
        let data = try await sendRaw(path: path, method: "GET", query: query, body: nil)
        return try decode(T.self, from: data)
    }

    private func decode<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
        do {
            return try JSONCoders.decoder.decode(T.self, from: data)
        } catch let error as DecodingError {
            throw APIError.decoding(detail: Self.describe(error))
        }
    }

    /// Renders a `DecodingError` into the string `APIError.decoding(detail:)`
    /// carries — the one deliberate exception to this package's "never
    /// report server-sent text" privacy contract (issue #106), because a
    /// systematic decode failure in the field is exactly the class of defect
    /// this whole effort exists to surface. The exception only holds because
    /// this formatter is narrowed to **code-derived facts alone**: the
    /// `DecodingError` case kind, the coding-key path, and — on
    /// `.typeMismatch`/`.valueNotFound` — the expected `Any.Type` Foundation
    /// itself supplies. Never `Context.debugDescription`.
    ///
    /// `debugDescription` is not incidental noise here — it is a live
    /// channel for verbatim server response content.
    /// `JSONCoders.decoder`'s custom date strategy builds exactly one as
    /// `"Unrecognized date format: \(raw)"`, where `raw` is the untouched
    /// wire string that failed to parse; the pre-#106 version of this
    /// formatter interpolated that string directly into every `.typeMismatch`
    /// and `.dataCorrupted` arm. Dropping it is what makes the "keep the
    /// detail" exception in the privacy contract honest rather than a loophole.
    ///
    /// The expected `Any.Type` on `.typeMismatch`/`.valueNotFound`, by
    /// contrast, is safe to include: Swift derives it from the *model's*
    /// declared property type (e.g. `Int.self`), never from the payload
    /// bytes, so it cannot hold anything a server sent. Including it
    /// restores most of the diagnostic power the `debugDescription` drop
    /// cost issue #77's original triage ("Expected to decode
    /// Dictionary<String, Any> but found an array instead") while staying
    /// provably payload-free.
    ///
    /// The `@unknown default:` arm is the one a test cannot construct —
    /// `DecodingError` has exactly four cases today, all handled above — but
    /// it must still be a **constant**, not `String(describing: error)`:
    /// `String(describing:)` on a `DecodingError` embeds the same
    /// `Context.debugDescription` this whole function exists to drop, so a
    /// future fifth case reaching this arm would silently reopen the channel
    /// through the one branch a test can't exercise to catch it.
    private static func describe(_ error: DecodingError) -> String {
        switch error {
        case .keyNotFound(let key, let ctx):
            return "missing key '\(key.stringValue)' at \(pathString(ctx.codingPath))"
        case .typeMismatch(let type, let ctx):
            return "type mismatch at \(pathString(ctx.codingPath)): expected \(type)"
        case .valueNotFound(let type, let ctx):
            return "null at \(pathString(ctx.codingPath)) (expected non-null \(type))"
        case .dataCorrupted(let ctx):
            return "data corrupted at \(pathString(ctx.codingPath))"
        @unknown default:
            return "unrecognized decoding error"
        }
    }

    private static func pathString(_ path: [any CodingKey]) -> String {
        path.map { $0.stringValue }.joined(separator: ".")
    }

    /// Decode an inflated NDJSON body — one ``CatalogRow`` per line,
    /// `\n`-separated (the `GET /library/catalog` wire shape; see
    /// `catalog-export.service.ts` `serializeCatalogNdjson`). It is **not** a
    /// JSON array, so it can't go through `JSONDecoder` in one shot. Blank and
    /// whitespace-only lines are skipped — a trailing newline, a blank
    /// separator, or a lone `\r` under CRLF aren't records, and `JSONDecoder`
    /// rejects a whitespace-only buffer as `dataCorrupted`; an empty body is
    /// therefore zero rows. A line with real content that fails to decode fails
    /// the whole fetch with a (physical-)line-numbered `.decoding` error, so the
    /// caller keeps its last-good clone rather than indexing a torn catalog.
    /// (Per-field dirt — a bad `artwork_url`, an unknown `rotation_bin` — is
    /// already tolerated inside ``CatalogRow``.) Pure transform — no instance
    /// state.
    private static func decodeNDJSON(_ data: Data) throws -> [CatalogRow] {
        var rows: [CatalogRow] = []
        // Keep empty subsequences so the reported line number is the physical
        // line position, then skip blank/whitespace-only lines explicitly.
        let lines = data.split(separator: UInt8(ascii: "\n"), omittingEmptySubsequences: false)
        for (index, line) in lines.enumerated() {
            if line.allSatisfy(isJSONWhitespace) { continue }
            do {
                rows.append(try JSONCoders.decoder.decode(CatalogRow.self, from: Data(line)))
            } catch let error as DecodingError {
                throw APIError.decoding(detail: "NDJSON line \(index + 1): \(describe(error))")
            }
        }
        return rows
    }

    /// The JSON grammar's insignificant-whitespace bytes (space, tab, LF, CR;
    /// RFC 8259 §2). Used to skip blank NDJSON separator lines instead of
    /// handing them to `JSONDecoder`, which rejects a whitespace-only buffer.
    private static func isJSONWhitespace(_ byte: UInt8) -> Bool {
        byte == 0x20 || byte == 0x09 || byte == 0x0A || byte == 0x0D
    }

    /// Map a non-success HTTP response to an `APIError`, decoding the server's
    /// `APIErrorResponse` message body when present. Shared by the 2xx-only
    /// ``sendRaw(path:method:query:body:)`` guard and ``catalog(ifModifiedSince:)``'s
    /// error arm so the error-body extraction (and the `401` → `.unauthorized`
    /// mapping) lives in one place.
    private static func httpError(status: Int, body: Data) -> APIError {
        if status == 401 { return .unauthorized }
        let message = (try? JSONCoders.decoder.decode(APIErrorResponse.self, from: body))?.message
        return .http(status: status, message: message)
    }

    /// 2xx-only transport: returns the body for a successful response or throws
    /// `.http`/`.unauthorized`. Thin policy layer over ``perform(path:method:query:body:extraHeaders:isRetry:)``.
    private func sendRaw(path: String, method: String, query: [URLQueryItem], body: Data?) async throws -> Data {
        let (data, http) = try await perform(path: path, method: method, query: query, body: body)
        guard (200..<300).contains(http.statusCode) else {
            throw Self.httpError(status: http.statusCode, body: data)
        }
        return data
    }

    /// Transport core shared by every typed method: attaches the bearer token,
    /// fires the request, and applies the one-shot `401` → `invalidateJWT` →
    /// retry. Returns the raw `(Data, HTTPURLResponse)` **without** imposing a
    /// status-code policy, so each caller decides which codes are acceptable —
    /// ``sendRaw(path:method:query:body:)`` requires 2xx; ``catalog(ifModifiedSince:)``
    /// additionally accepts `304`. `extraHeaders` carries request headers the
    /// typed signature doesn't model (e.g. `If-Modified-Since`).
    private func perform(
        path: String,
        method: String,
        query: [URLQueryItem],
        body: Data?,
        extraHeaders: [String: String] = [:],
        isRetry: Bool = false
    ) async throws -> (Data, HTTPURLResponse) {
        let token = try await currentJWT()
        var request = try buildRequest(path: path, method: method, query: query, body: body, token: token)
        for (field, value) in extraHeaders {
            request.setValue(value, forHTTPHeaderField: field)
        }
        let (data, response) = try await fire(request)
        guard let http = response as? HTTPURLResponse else {
            throw APIError.network("Non-HTTP response")
        }
        if http.statusCode == 401, !isRetry {
            await authService.invalidateJWT()
            return try await perform(
                path: path, method: method, query: query, body: body,
                extraHeaders: extraHeaders, isRetry: true
            )
        }
        return (data, http)
    }

    private func buildRequest(path: String, method: String, query: [URLQueryItem], body: Data?, token: String) throws -> URLRequest {
        var components = URLComponents(url: configuration.apiBaseURL.appending(path: path), resolvingAgainstBaseURL: false)
        if !query.isEmpty { components?.queryItems = query }
        guard let url = components?.url else {
            throw APIError.network("Failed to build URL for \(path)")
        }
        var request = URLRequest(url: url, timeoutInterval: configuration.timeout)
        request.httpMethod = method
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let body {
            request.httpBody = body
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        return request
    }

    private func fire(_ request: URLRequest) async throws -> (Data, URLResponse) {
        do {
            let result = try await session.data(for: request)
            // The server answered (any status code) — we reached it, so the
            // connection is up regardless of what the response says.
            onOutcome?(true)
            return result
        } catch let error as URLError where error.code == .cancelled {
            // A cancelled request says nothing about connectivity — the caller
            // superseded the call (the issue-#58 search debounce cancels the
            // in-flight task on every keystroke), it didn't fail to reach the
            // server. Reporting offline here would wrongly route later searches
            // to the local clone while the device is online, and a local search
            // issues no request, so nothing would restore the flag. Surface the
            // failure without latching the monitor.
            //
            // `.offline` below (not `.network`) is what keeps this routine
            // cancellation from ever reaching crash telemetry (issue #106) —
            // `ConnectivityErrorClassification` includes `.cancelled` in its
            // connectivity-code set deliberately, not by omission; see
            // ``APIError/offline(message:)``'s doc comment.
            throw Self.classifyTransportFailure(error)
        } catch is CancellationError {
            // Same rationale for structured-concurrency cancellation surfaced as
            // CancellationError (a RequestSession may map it that way). Not a
            // URLError, so classifyTransportFailure can't classify it by code —
            // but cancellation is cancellation regardless of which type carries
            // it, so this is unconditionally `.offline`, never `.network`.
            throw APIError.offline(message: "Request cancelled")
        } catch {
            // A thrown error from the transport means we never reached the
            // server (no network, captive portal, DNS, timeout): report offline.
            onOutcome?(false)
            throw Self.classifyTransportFailure(error)
        }
    }

    /// The classification shared by every site in this file that discards a
    /// raw, non-`APIError` transport error into this enum: ``fire(_:)``'s
    /// catch-all above, and ``currentJWT()``'s below (the lazy JWT-refresh
    /// leg `AuthService.currentJWT()` drives can itself fail offline, one
    /// layer below `fire` — see that method's doc comment). Mirrors
    /// `AuthService.classifyTransportFailure` (issue #106): a
    /// connectivity-class `URLError` becomes ``APIError/offline(message:)``;
    /// everything else is a genuine transport defect and stays
    /// ``APIError/network(_:)``. One home so the two sites can't quietly
    /// diverge on what counts as "offline".
    private static func classifyTransportFailure(_ error: Error) -> APIError {
        ConnectivityErrorClassification.isConnectivityFailure(error)
            ? .offline(message: error.localizedDescription)
            : .network(error.localizedDescription)
    }

    private func currentJWT() async throws -> String {
        do {
            return try await authService.currentJWT()
        } catch AuthError.notSignedIn {
            throw APIError.notSignedIn
        } catch {
            throw Self.classifyTransportFailure(error)
        }
    }
}
