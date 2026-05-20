//
//  APIClient.swift
//  WXYCAPI
//
//  Thin URLSession wrapper that hits Backend-Service routes. Calls
//  AuthService.currentJWT() to attach a Bearer token, retries once on a 401
//  (which forces a JWT refresh), and exposes typed methods for the four
//  endpoints the DJ tool consumes: library search, /library/info, GET/POST/
//  DELETE /djs/bin.
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

    private func sendRaw(path: String, method: String, query: [URLQueryItem], body: Data?, isRetry: Bool = false) async throws -> Data {
        let token = try await currentJWT()
        let request = try buildRequest(path: path, method: method, query: query, body: body, token: token)
        let (data, response) = try await fire(request)
        guard let http = response as? HTTPURLResponse else {
            throw APIError.network("Non-HTTP response")
        }
        if http.statusCode == 401, !isRetry {
            await authService.invalidateJWT()
            return try await sendRaw(path: path, method: method, query: query, body: body, isRetry: true)
        }
        guard (200..<300).contains(http.statusCode) else {
            let message = (try? JSONCoders.decoder.decode(APIErrorResponse.self, from: data))?.message
            if http.statusCode == 401 { throw APIError.unauthorized }
            throw APIError.http(status: http.statusCode, message: message)
        }
        return data
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
