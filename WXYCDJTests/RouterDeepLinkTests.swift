//
//  RouterDeepLinkTests.swift
//  WXYCDJTests
//
//  Pins the Spotlight deep-link replay logic (issue #19 step 7): a tap that
//  arrives while signed out / mid-restoreSession() parks its album id in
//  Router.pending and is replayed into Router.deepLink the moment auth resolves
//  to .signedIn; a tap while already signed in presents immediately. A clone hit
//  carries the looked-up row's detailFallback for an instant header render; a
//  clone miss routes with fallback: nil (AlbumDetailView then awaits
//  /library/info). The signed-in gate is passed in explicitly so the replay is
//  testable without driving a real sign-in.
//
//  Created by Jake on 6/23/26.
//  Copyright © 2026 WXYC. All rights reserved.
//

import Foundation
import Testing
import WXYCAPI
@testable import WXYCDJ

@Suite("Router deep-link replay")
@MainActor
struct RouterDeepLinkTests {
    /// An AppDependencies backed by a fresh temp SQLite store, plus the store
    /// URL so the caller can clean up the sidecar files.
    private static func makeDeps() -> (AppDependencies, URL) {
        let url = FileManager.default.temporaryDirectory
            .appending(path: "router-deeplink-\(UUID().uuidString).sqlite")
        return (AppDependencies(catalogStoreURL: url), url)
    }

    private static func cleanup(_ url: URL) {
        let base = url.path(percentEncoded: false)
        try? FileManager.default.removeItem(at: url)
        for suffix in ["-journal", "-wal", "-shm"] {
            try? FileManager.default.removeItem(at: URL(filePath: base + suffix))
        }
    }

    /// A WXYC-representative cloned catalog row (Juana Molina / DOGA).
    private static func dogaRow(id: Int = 100) -> CatalogRow {
        CatalogRow(
            id: id,
            artistName: "Juana Molina",
            albumTitle: "DOGA",
            codeLetters: "MOL",
            codeNumber: 12,
            codeArtistNumber: 1,
            label: "Sonamos",
            genreName: "Rock",
            formatName: "CD",
            onStreaming: true,
            plays: 7,
            artworkURL: nil,
            rotationBin: "H",
            rotationKillDate: nil
        )
    }

    @Test func tapWhileSignedOutStashesPending() async throws {
        let (deps, url) = Self.makeDeps()
        defer { Self.cleanup(url) }
        try await #require(deps.catalogStore).replace(rows: [Self.dogaRow()], lastModified: nil)

        await deps.handleSpotlightTap(albumID: 100, isSignedIn: false)

        // Parked, not presented — never surfaces over the cold-launch spinner.
        #expect(deps.router.deepLink == nil)
        #expect(deps.router.pending == 100)
    }

    @Test func coldLaunchSignedOutResolutionKeepsParkForLaterSignIn() async {
        // restoreSession() resolving to .signedOut (no session) is .unknown →
        // .signedOut: NOT a genuine sign-out, so a tap parked before sign-in
        // survives for the DJ's later manual sign-in. The path never reaches the
        // store, so skip the temp file (mirrors tapPresentsEvenWhenCatalogStoreIsInert).
        let deps = AppDependencies(catalogStoreURL: nil)
        await deps.handleSpotlightTap(albumID: 100, isSignedIn: false)

        await deps.handleAuthChange(wasSignedIn: false, isSignedIn: false)

        #expect(deps.router.deepLink == nil)
        #expect(deps.router.pending == 100)  // still parked for a later sign-in
    }

    @Test func replayOnSignedInPresentsWithCloneFallback() async throws {
        let (deps, url) = Self.makeDeps()
        defer { Self.cleanup(url) }
        try await #require(deps.catalogStore).replace(rows: [Self.dogaRow()], lastModified: nil)

        await deps.handleSpotlightTap(albumID: 100, isSignedIn: false)         // cold-launch park
        await deps.handleAuthChange(wasSignedIn: false, isSignedIn: true)      // auth resolved → replay

        let route = try #require(deps.router.deepLink)
        #expect(route.id == 100)
        // Clone hit: the looked-up row's detailFallback renders the header instantly.
        #expect(route.fallback?.albumTitle == "DOGA")
        #expect(route.fallback?.artistName == "Juana Molina")
        #expect(deps.router.pending == nil)
    }

    @Test func signOutTearsDownPresentedCover() async throws {
        let (deps, url) = Self.makeDeps()
        defer { Self.cleanup(url) }
        try await #require(deps.catalogStore).replace(rows: [Self.dogaRow()], lastModified: nil)

        // A signed-in DJ is viewing a deep-linked album...
        await deps.handleSpotlightTap(albumID: 100, isSignedIn: true)
        #expect(deps.router.deepLink != nil)

        // ...then signs out (.signedIn → .signedOut): the cover must be dismissed
        // so a detail can't strand over LoginView issuing 401s.
        await deps.handleAuthChange(wasSignedIn: true, isSignedIn: false)

        #expect(deps.router.deepLink == nil)
        #expect(deps.router.pending == nil)
    }

    @Test func tapWhileSignedInPresentsImmediatelyWithCloneFallback() async throws {
        let (deps, url) = Self.makeDeps()
        defer { Self.cleanup(url) }
        try await #require(deps.catalogStore).replace(rows: [Self.dogaRow()], lastModified: nil)

        await deps.handleSpotlightTap(albumID: 100, isSignedIn: true)

        let route = try #require(deps.router.deepLink)
        #expect(route.id == 100)
        #expect(route.fallback?.albumTitle == "DOGA")
        #expect(deps.router.pending == nil)
    }

    @Test func tapWhileSignedInCloneMissRoutesWithNilFallback() async throws {
        let (deps, url) = Self.makeDeps()
        defer { Self.cleanup(url) }
        // Store openable but no row for this id — the clone-miss path.
        try await #require(deps.catalogStore).replace(rows: [Self.dogaRow(id: 100)], lastModified: nil)

        await deps.handleSpotlightTap(albumID: 999, isSignedIn: true)

        let route = try #require(deps.router.deepLink)
        #expect(route.id == 999)
        // No fallback — AlbumDetailView resolves the row by awaiting /library/info.
        #expect(route.fallback == nil)
    }

    @Test func drainOnSignedInCloneMissReplaysWithNilFallback() async throws {
        let (deps, url) = Self.makeDeps()
        defer { Self.cleanup(url) }
        // A row exists, but not for the tapped id — the cold-launch replay's
        // clone-miss path (symmetry with the immediate-tap miss above).
        try await #require(deps.catalogStore).replace(rows: [Self.dogaRow(id: 100)], lastModified: nil)

        await deps.handleSpotlightTap(albumID: 999, isSignedIn: false)    // park a miss
        await deps.handleAuthChange(wasSignedIn: false, isSignedIn: true) // replay

        let route = try #require(deps.router.deepLink)
        #expect(route.id == 999)
        #expect(route.fallback == nil)
        #expect(deps.router.pending == nil)
    }

    @Test func tapPresentsEvenWhenCatalogStoreIsInert() async throws {
        // A degraded device (disk unwritable) leaves catalogStore nil. The deep
        // link must still present — just without a clone fallback — so home-screen
        // search remains tappable; AlbumDetailView resolves via /library/info.
        let deps = AppDependencies(catalogStoreURL: nil)
        #expect(deps.catalogStore == nil)

        await deps.handleSpotlightTap(albumID: 100, isSignedIn: true)

        let route = try #require(deps.router.deepLink)
        #expect(route.id == 100)
        #expect(route.fallback == nil)
    }

    @Test func signedInTapClearsAnEarlierStash() async throws {
        let (deps, url) = Self.makeDeps()
        defer { Self.cleanup(url) }
        try await #require(deps.catalogStore).replace(rows: [Self.dogaRow(id: 200)], lastModified: nil)

        await deps.handleSpotlightTap(albumID: 100, isSignedIn: false)  // park 100
        await deps.handleSpotlightTap(albumID: 200, isSignedIn: true)   // then a signed-in tap

        let route = try #require(deps.router.deepLink)
        #expect(route.id == 200)
        #expect(deps.router.pending == nil)  // the stale stash is cleared
    }

    @Test func concurrentPresentationsMostRecentWins() async throws {
        // The token bow-out branch the sequential-await tests can't reach: two
        // presentations interleaved across the resolveRoute suspension. A
        // signed-in tap for 100 suspends inside the store's row(100) (token 1); a
        // second tap for 200 then suspends in row(200) (token 2); when both reads
        // release, the most-recently-requested album (200) wins and the stale 100
        // bows out on the `guard token == presentationToken`. A GatedCatalogStore
        // makes the interleaving deterministic instead of timing-dependent.
        let store = GatedCatalogStore(rows: [Self.dogaRow(id: 100), Self.dogaRow(id: 200)])
        let deps = AppDependencies(catalogStore: store)

        let first = Task { await deps.handleSpotlightTap(albumID: 100, isSignedIn: true) }
        await store.waitUntilEntered(count: 1)   // present(100) suspended, token = 1
        let second = Task { await deps.handleSpotlightTap(albumID: 200, isSignedIn: true) }
        await store.waitUntilEntered(count: 2)   // present(200) suspended, token = 2
        await store.release()                    // both row() reads return
        _ = await first.value
        _ = await second.value

        // Fresh wins; the stale 100 bowed out rather than clobbering the cover.
        #expect(deps.router.deepLink?.id == 200)
        #expect(deps.router.pending == nil)
    }
}

/// A `CatalogStore` whose `row(id:)` records the requested id then blocks until
/// ``release()``, so a test can suspend two `present(albumID:)` calls inside the
/// store read at once and deterministically exercise the most-recent-wins token
/// latch. An `actor`, so it's `Sendable` and its bookkeeping is race-free.
private actor GatedCatalogStore: CatalogStore {
    private var rowsByID: [Int: CatalogRow]
    private var enteredCount = 0
    private var released = false
    private var rowWaiters: [CheckedContinuation<Void, Never>] = []
    private var enteredWaiters: [(needed: Int, continuation: CheckedContinuation<Void, Never>)] = []

    init(rows: [CatalogRow]) {
        rowsByID = Dictionary(uniqueKeysWithValues: rows.map { ($0.id, $0) })
    }

    func row(id: Int) async -> CatalogRow? {
        enteredCount += 1
        let reached = enteredCount
        let woken = enteredWaiters.filter { reached >= $0.needed }
        enteredWaiters.removeAll { reached >= $0.needed }
        for waiter in woken { waiter.continuation.resume() }
        if !released {
            await withCheckedContinuation { rowWaiters.append($0) }
        }
        return rowsByID[id]
    }

    /// Suspend until at least `count` `row(id:)` calls have entered.
    func waitUntilEntered(count: Int) async {
        if enteredCount >= count { return }
        await withCheckedContinuation { enteredWaiters.append((count, $0)) }
    }

    /// Unblock every suspended (and future) `row(id:)` read.
    func release() {
        released = true
        let waiters = rowWaiters
        rowWaiters.removeAll()
        for waiter in waiters { waiter.resume() }
    }

    // Remaining CatalogStore surface — unused by the deep-link resolution path.
    func count() async throws -> Int { rowsByID.count }
    func lastModified() async throws -> String? { nil }
    func replace(rows: [CatalogRow], lastModified: String?) async throws {
        rowsByID = Dictionary(uniqueKeysWithValues: rows.map { ($0.id, $0) })
    }
    func search(query: String, limit: Int) async throws -> [CatalogRow] { [] }
}
