//
//  ThumbnailProviding.swift
//  WXYCAPI
//
//  The Sendable seam (+ on-disk implementation) for resolving an album's Spotlight
//  thumbnail (issue #44): given a CatalogRow, return a cached local JPEG file URL,
//  fetching + downscaling + writing on a miss. The cache is the fetch-dedup ledger
//  (keyed id + artwork_url hash, atomic writes, per-key single-flight); the Spotlight
//  index owns the embedded bytes, so the cache is never load-bearing for "does the
//  index still have the art". Network + disk live behind this seam so the lazy
//  cacheThumbnail path stays off the main actor and host-testable against a fake.
//
//  Created by Jake on 06/24/26.
//  Copyright © 2026 WXYC. All rights reserved.
//

import CryptoKit
import Foundation
import OSLog

private let thumbnailLog = Logger(subsystem: "org.wxyc.dj", category: "thumbnail")

/// Resolves an album's on-device Spotlight thumbnail. `Sendable` so the lazy
/// `cacheThumbnail` path can call it off the main actor; the caller reads bytes off
/// the returned file URL to build the embedded `thumbnailData` right before the
/// upsert, keeping the pure `CatalogRow → CSSearchableItem` mapping network-free.
public protocol ThumbnailProviding: Sendable {
    /// The cached local JPEG file URL for `row`'s cover, fetching + downscaling +
    /// writing it on a miss. `nil` when `row` has no `artwork_url`, or the fetch /
    /// decode / write fails — best-effort decoration, never a thrown error (the row
    /// just shows the default icon).
    func localThumbnailURL(for row: CatalogRow) async -> URL?
}

/// On-disk `ThumbnailProviding`: caches downscaled JPEG covers under a directory
/// (production: `<Application Support>/Catalog/Thumbnails/`). An `actor` so the
/// per-key single-flight ledger is race-free without a lock, and so the fetch /
/// downscale / write run off the main actor.
public actor DiskThumbnailProvider: ThumbnailProviding {
    private let directory: URL
    private let session: any RequestSession
    private let maxPixelDimension: Int
    private let fileManager = FileManager.default
    /// In-flight fetches keyed by cache filename, so a fast re-view (the same album
    /// surfaced twice) coalesces onto one network round-trip instead of double-fetching.
    private var inFlight: [String: Task<URL?, Never>] = [:]

    public init(
        directory: URL,
        session: any RequestSession = URLSession.shared,
        maxPixelDimension: Int = ThumbnailDownscaler.defaultMaxPixelDimension
    ) {
        self.directory = directory
        self.session = session
        self.maxPixelDimension = maxPixelDimension
        // Best-effort: ensure the cache dir exists so writes don't fail on first use.
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    public func localThumbnailURL(for row: CatalogRow) async -> URL? {
        guard let artworkURL = row.artworkURL else { return nil }
        let key = Self.cacheKey(id: row.id, url: artworkURL)
        let fileURL = directory.appending(path: key, directoryHint: .notDirectory)

        // Cache hit — O(1), no network. (A changed artwork_url hashes to a new key,
        // so this naturally misses and re-fetches; the stale file is left for the
        // global size cap to reclaim, a PR-2 concern.)
        if fileManager.fileExists(atPath: fileURL.path) { return fileURL }

        // Single-flight: coalesce a concurrent same-key request onto the in-flight
        // fetch. `inFlight[key]` is set synchronously before the first `await`
        // below, so a second caller entering the actor always sees it.
        if let existing = inFlight[key] { return await existing.value }
        let task = Task { await self.fetchDownscaleStore(from: artworkURL, to: fileURL) }
        inFlight[key] = task
        let result = await task.value
        inFlight[key] = nil
        return result
    }

    /// Fetch `url`, downscale to a JPEG, and write it atomically to `fileURL`.
    /// Returns `fileURL` on success, `nil` on any failure (logged) — the cover just
    /// falls back to the default Spotlight icon. Runs on the actor; the network
    /// `await` releases it so a coalesced caller can observe the in-flight task.
    private func fetchDownscaleStore(from url: URL, to fileURL: URL) async -> URL? {
        do {
            let (data, response) = try await session.data(for: URLRequest(url: url))
            guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
                thumbnailLog.debug("thumbnail fetch non-2xx for \(url.absoluteString, privacy: .public)")
                return nil
            }
            guard let jpeg = ThumbnailDownscaler.downscaledJPEG(from: data, maxPixelDimension: maxPixelDimension) else {
                thumbnailLog.debug("thumbnail undecodable for \(url.absoluteString, privacy: .public)")
                return nil
            }
            // Atomic write (writes to a temp file then renames) so a torn/partial
            // file can never be read by Spotlight or a concurrent caller.
            try jpeg.write(to: fileURL, options: .atomic)
            return fileURL
        } catch {
            thumbnailLog.debug("thumbnail fetch/write failed for \(url.absoluteString, privacy: .public): \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }

    /// `<id>-<urlhash>.jpg`: the id namespaces the file and the URL hash invalidates
    /// it when the cover changes (a changed `artwork_url` → new key → re-fetch). The
    /// hash is the first 16 hex chars of SHA-256 over the URL string — short enough
    /// for a tidy filename, wide enough (64 bits) that a collision within one album's
    /// covers is negligible.
    static func cacheKey(id: Int, url: URL) -> String {
        let digest = SHA256.hash(data: Data(url.absoluteString.utf8))
        let hex = digest.map { String(format: "%02x", $0) }.joined().prefix(16)
        return "\(id)-\(hex).jpg"
    }
}
