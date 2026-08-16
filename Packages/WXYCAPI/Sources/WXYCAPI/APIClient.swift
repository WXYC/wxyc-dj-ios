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

    public var localizedMessage: String {
        switch self {
        case .unauthorized: "Your session expired. Please sign in again."
        case .notSignedIn: "Please sign in."
        case .http(let s, let m): "Server error (\(s))\(m.map { ": \($0)" } ?? "")."
        case .decoding(let detail): "The server returned an unexpected response: \(detail)"
        case .network(let m): "Network error: \(m)"
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
    private let session: any RequestSession
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
        self.session = session
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
    /// A literal `null` body is a **decoding error, not an empty bin** —
    /// deliberately unlike dj-site, which coerces it (`BinLibraryDetails[] |
    /// null`). dj-site has no offline snapshot to protect; we do, and
    /// `BinViewModel` persists whatever this returns. Coercing `null` to `[]`
    /// would overwrite the DJ's last-good offline bin with *authoritative*
    /// emptiness (the store's snapshot-present marker), so the Bin tab would
    /// read "Bin is empty" across cold launches until a real refresh landed.
    /// Throwing instead keeps the snapshot on screen — the same fail-closed
    /// posture as `catalog()`'s `.skippedEmptyExport` guard, and for the same
    /// reason: an empty body is likelier a backend hiccup than a real empty
    /// bin. A genuinely empty bin arrives as `[]` and still persists as
    /// authoritative emptiness, which is issue #60's whole written-empty vs.
    /// never-written distinction.
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

    private static func describe(_ error: DecodingError) -> String {
        switch error {
        case .keyNotFound(let key, let ctx):
            return "missing key '\(key.stringValue)' at \(pathString(ctx.codingPath))"
        case .typeMismatch(_, let ctx):
            return "type mismatch at \(pathString(ctx.codingPath)): \(ctx.debugDescription)"
        case .valueNotFound(_, let ctx):
            return "null at \(pathString(ctx.codingPath)) (expected non-null)"
        case .dataCorrupted(let ctx):
            return "data corrupted at \(pathString(ctx.codingPath)): \(ctx.debugDescription)"
        @unknown default:
            return String(describing: error)
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
            throw APIError.network(error.localizedDescription)
        } catch is CancellationError {
            // Same rationale for structured-concurrency cancellation surfaced as
            // CancellationError (a RequestSession may map it that way).
            throw APIError.network("Request cancelled")
        } catch {
            // A thrown error from the transport means we never reached the
            // server (no network, captive portal, DNS, timeout): report offline.
            onOutcome?(false)
            throw APIError.network(error.localizedDescription)
        }
    }

    private func currentJWT() async throws -> String {
        do {
            return try await authService.currentJWT()
        } catch AuthError.notSignedIn {
            throw APIError.notSignedIn
        } catch {
            throw APIError.network(error.localizedDescription)
        }
    }
}
