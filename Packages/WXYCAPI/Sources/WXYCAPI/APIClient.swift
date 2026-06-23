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

    public init(
        configuration: WXYCAPIConfiguration,
        session: any RequestSession = URLSession.shared,
        authService: AuthService
    ) {
        self.configuration = configuration
        self.session = session
        self.authService = authService
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
        case 200..<300:
            return .modified(
                rows: try decodeNDJSON(data),
                lastModified: http.value(forHTTPHeaderField: "Last-Modified")
            )
        case 401:
            throw APIError.unauthorized
        default:
            let message = (try? JSONCoders.decoder.decode(APIErrorResponse.self, from: data))?.message
            throw APIError.http(status: http.statusCode, message: message)
        }
    }

    public func getBin() async throws -> DJBinResponse {
        try await getJSON("/djs/bin", query: [])
    }

    @discardableResult
    public func addToBin(albumId: Int, trackTitle: String? = nil) async throws -> BinEntry {
        try await postJSON("/djs/bin", body: AddToBinRequest(albumId: albumId, trackTitle: trackTitle))
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

    private func postJSON<B: Encodable, T: Decodable>(_ path: String, body: B) async throws -> T {
        let encoded = try JSONCoders.encoder.encode(body)
        let data = try await sendRaw(path: path, method: "POST", query: [], body: encoded)
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
    /// `\n`-separated with no trailing newline (the `GET /library/catalog` wire
    /// shape; see `catalog-export.service.ts` `serializeCatalogNdjson`). It is
    /// **not** a JSON array, so it can't go through `JSONDecoder` in one shot.
    /// An empty body (the server's empty-catalog form) yields zero rows. A
    /// structurally malformed line fails the whole fetch with a line-numbered
    /// `.decoding` error — the caller then keeps its last-good clone rather than
    /// indexing a torn catalog. (Per-field dirt — a bad `artwork_url`, an
    /// unknown `rotation_bin` — is already tolerated inside ``CatalogRow``.)
    private func decodeNDJSON(_ data: Data) throws -> [CatalogRow] {
        var rows: [CatalogRow] = []
        var lineNumber = 0
        for line in data.split(separator: UInt8(ascii: "\n"), omittingEmptySubsequences: true) {
            lineNumber += 1
            do {
                rows.append(try JSONCoders.decoder.decode(CatalogRow.self, from: Data(line)))
            } catch let error as DecodingError {
                throw APIError.decoding(detail: "NDJSON line \(lineNumber): \(Self.describe(error))")
            }
        }
        return rows
    }

    /// 2xx-only transport: returns the body for a successful response or throws
    /// `.http`/`.unauthorized`. Thin policy layer over ``perform(path:method:query:body:extraHeaders:isRetry:)``.
    private func sendRaw(path: String, method: String, query: [URLQueryItem], body: Data?) async throws -> Data {
        let (data, http) = try await perform(path: path, method: method, query: query, body: body)
        guard (200..<300).contains(http.statusCode) else {
            let message = (try? JSONCoders.decoder.decode(APIErrorResponse.self, from: data))?.message
            if http.statusCode == 401 { throw APIError.unauthorized }
            throw APIError.http(status: http.statusCode, message: message)
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
            return try await session.data(for: request)
        } catch {
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
