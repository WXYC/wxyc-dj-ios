//
//  DiskThumbnailProviderTests.swift
//  WXYCAPITests
//
//  Tests the on-disk thumbnail cache (issue #44): a miss fetches the remote cover,
//  downscales it, and writes it atomically; a hit returns the cached file with no
//  network; a changed artwork_url re-fetches under a new key; absent/unfetchable
//  artwork resolves to nil; concurrent same-key resolves single-flight to one
//  fetch. The cache is the fetch-dedup ledger — the index owns the embedded bytes.
//
//  Created by Jake on 06/24/26.
//  Copyright © 2026 WXYC. All rights reserved.
//

import Foundation
import Testing
@testable import WXYCAPI

@Suite("DiskThumbnailProvider")
struct DiskThumbnailProviderTests {
    /// A fresh, isolated cache directory under the temp dir, removed after `body`.
    static func withTempDirectory(_ body: (URL) async throws -> Void) async throws {
        let dir = FileManager.default.temporaryDirectory
            .appending(path: "thumb-cache-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: dir) }
        try await body(dir)
    }

    /// A catalog row with the given id + artwork URL (the only fields the provider reads).
    static func row(_ id: Int, artwork: String?) -> CatalogRow {
        CatalogRow(
            id: id, artistName: "Artist \(id)", albumTitle: "Album \(id)",
            codeLetters: nil, codeNumber: nil, codeArtistNumber: nil,
            label: nil, genreName: nil, formatName: nil,
            onStreaming: nil, plays: nil, artworkURL: artwork.flatMap(URL.init(string:)),
            rotationBin: nil, rotationKillDate: nil
        )
    }

    @Test func missFetchesDownscalesWritesAndReturnsAFileURL() async throws {
        try await Self.withTempDirectory { dir in
            let session = StubRequestSession()
            session.enqueue(StubRequestSession.Stub(
                statusCode: 200,
                body: ThumbnailDownscalingTests.makeJPEG(width: 600, height: 600)
            ))
            let provider = DiskThumbnailProvider(directory: dir, session: session)

            let url = try #require(await provider.localThumbnailURL(
                for: Self.row(100, artwork: "https://img.discogs.com/doga.jpg")))

            // A real local file was written...
            #expect(url.isFileURL)
            let bytes = try Data(contentsOf: url)
            // ...holding a downscaled JPEG (longest side <= 256), not the original.
            let size = try #require(ThumbnailDownscalingTests.pixelSize(of: bytes))
            #expect(max(size.width, size.height) <= 256)
            // Exactly one fetch.
            #expect(session.recordedRequests.count == 1)
        }
    }

    @Test func hitReturnsTheCachedFileWithoutFetchingAgain() async throws {
        try await Self.withTempDirectory { dir in
            let session = StubRequestSession()
            session.enqueue(StubRequestSession.Stub(
                statusCode: 200, body: ThumbnailDownscalingTests.makeJPEG(width: 400, height: 400)))
            let provider = DiskThumbnailProvider(directory: dir, session: session)
            let row = Self.row(100, artwork: "https://img.discogs.com/doga.jpg")

            let first = try #require(await provider.localThumbnailURL(for: row))
            let second = try #require(await provider.localThumbnailURL(for: row))

            #expect(first == second)
            // No re-download: the second resolve was a pure cache hit.
            #expect(session.recordedRequests.count == 1)
        }
    }

    @Test func changedArtworkURLReFetchesUnderANewKey() async throws {
        try await Self.withTempDirectory { dir in
            let session = StubRequestSession()
            session.enqueue(StubRequestSession.Stub(
                statusCode: 200, body: ThumbnailDownscalingTests.makeJPEG(width: 400, height: 400)))
            session.enqueue(StubRequestSession.Stub(
                statusCode: 200, body: ThumbnailDownscalingTests.makeJPEG(width: 400, height: 400)))
            let provider = DiskThumbnailProvider(directory: dir, session: session)

            // Same album id, different cover URL (an LML re-enrichment) -> a new key,
            // so it invalidates and re-fetches exactly once.
            let old = try #require(await provider.localThumbnailURL(
                for: Self.row(100, artwork: "https://img.discogs.com/old.jpg")))
            let new = try #require(await provider.localThumbnailURL(
                for: Self.row(100, artwork: "https://img.discogs.com/new.jpg")))

            #expect(old != new)
            #expect(session.recordedRequests.count == 2)
        }
    }

    @Test func nilArtworkURLReturnsNilWithoutFetching() async throws {
        try await Self.withTempDirectory { dir in
            let session = StubRequestSession()
            let provider = DiskThumbnailProvider(directory: dir, session: session)

            let url = await provider.localThumbnailURL(for: Self.row(100, artwork: nil))

            #expect(url == nil)
            #expect(session.recordedRequests.isEmpty)
        }
    }

    @Test func fetchFailureReturnsNilAndWritesNoFile() async throws {
        try await Self.withTempDirectory { dir in
            let session = StubRequestSession()
            session.enqueue(StubRequestSession.Stub(statusCode: 404))   // a dead CDN URL
            let provider = DiskThumbnailProvider(directory: dir, session: session)

            let url = await provider.localThumbnailURL(
                for: Self.row(100, artwork: "https://img.discogs.com/gone.jpg"))

            #expect(url == nil)
            // Nothing cached -> a later view can retry rather than caching a failure.
            let contents = try FileManager.default.contentsOfDirectory(atPath: dir.path)
            #expect(contents.isEmpty)
        }
    }

    @Test func concurrentSameKeyResolvesSingleFlightToOneFetch() async throws {
        try await Self.withTempDirectory { dir in
            // A blocking session holds the fetch open so BOTH calls are in-flight at
            // once, forcing the second through the single-flight (inFlight) branch
            // rather than a cache hit.
            let session = BlockingRequestSession(body: ThumbnailDownscalingTests.makeJPEG(width: 400, height: 400))
            let provider = DiskThumbnailProvider(directory: dir, session: session)
            let row = Self.row(100, artwork: "https://img.discogs.com/doga.jpg")

            async let a = provider.localThumbnailURL(for: row)
            async let b = provider.localThumbnailURL(for: row)
            // Let both calls reach the actor and the second coalesce onto the first's
            // in-flight task before the fetch is allowed to complete.
            await session.waitForFirstRequest()
            session.release()
            let (urlA, urlB) = await (a, b)

            #expect(urlA != nil)
            #expect(urlA == urlB)
            #expect(session.requestCount == 1)   // coalesced, not double-fetched
        }
    }
}
