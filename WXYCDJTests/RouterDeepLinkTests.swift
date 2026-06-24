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

    @Test func drainWhileStillSignedOutIsNoOp() async throws {
        let (deps, url) = Self.makeDeps()
        defer { Self.cleanup(url) }
        await deps.handleSpotlightTap(albumID: 100, isSignedIn: false)

        // restoreSession() resolved to signedOut, not signedIn: nothing replays.
        await deps.drainPendingDeepLink(isSignedIn: false)

        #expect(deps.router.deepLink == nil)
        #expect(deps.router.pending == 100)  // still parked for a later sign-in
    }

    @Test func drainOnSignedInPresentsWithCloneFallback() async throws {
        let (deps, url) = Self.makeDeps()
        defer { Self.cleanup(url) }
        try await #require(deps.catalogStore).replace(rows: [Self.dogaRow()], lastModified: nil)

        await deps.handleSpotlightTap(albumID: 100, isSignedIn: false)  // cold-launch park
        await deps.drainPendingDeepLink(isSignedIn: true)               // auth resolved → replay

        let route = try #require(deps.router.deepLink)
        #expect(route.id == 100)
        // Clone hit: the looked-up row's detailFallback renders the header instantly.
        #expect(route.fallback?.albumTitle == "DOGA")
        #expect(route.fallback?.artistName == "Juana Molina")
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

        await deps.handleSpotlightTap(albumID: 999, isSignedIn: false)  // park a miss
        await deps.drainPendingDeepLink(isSignedIn: true)               // replay

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
}
