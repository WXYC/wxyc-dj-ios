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
    /// URL so the caller can clean up the sidecar files. `analytics` is
    /// threaded through rather than left to a second, spied `AppDependencies`
    /// built over the same store: two instances share one `CatalogStore` but
    /// get *separate* `Router`s, so an assertion accidentally written against
    /// the unspied one's `router` would pass vacuously.
    private static func makeDeps(
        analytics: any Analytics = NoOpAnalytics(),
        engine: any PlaybackEngine = InertPlaybackEngine()
    ) -> (AppDependencies, URL) {
        let url = FileManager.default.temporaryDirectory
            .appending(path: "router-deeplink-\(UUID().uuidString).sqlite")
        return (AppDependencies(catalogStoreURL: url, analytics: analytics, engine: engine), url)
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
        #expect(deps.router.pending == DeepLinkRequest(albumID: 100, source: .spotlight))
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
        #expect(deps.router.pending == DeepLinkRequest(albumID: 100, source: .spotlight))  // still parked for a later sign-in
    }

    @Test func replayOnSignedInPresentsWithCloneFallback() async throws {
        let (deps, url) = Self.makeDeps()
        defer { Self.cleanup(url) }
        try await #require(deps.catalogStore).replace(rows: [Self.dogaRow()], lastModified: nil)

        await deps.handleSpotlightTap(albumID: 100, isSignedIn: false)         // cold-launch park
        await deps.handleAuthChange(wasSignedIn: false, isSignedIn: true)      // auth resolved → replay

        let presented = try #require(deps.router.deepLink)
        #expect(presented.id == 100)
        // Clone hit: the looked-up row's detailFallback renders the header instantly.
        #expect(presented.route.fallback?.albumTitle == "DOGA")
        #expect(presented.route.fallback?.artistName == "Juana Molina")
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

    @Test func signOutStopsArchivePlayback() async throws {
        let engine = SpyPlaybackEngine()
        let (deps, url) = Self.makeDeps(engine: engine)
        defer { Self.cleanup(url) }
        deps.playbackController.start(
            manifest: PlaybackFixtures.threeTrackManifest(),
            albumTitle: "DOGA",
            artistName: "Juana Molina"
        )
        #expect(deps.playbackController.currentItem != nil)

        await deps.handleAuthChange(wasSignedIn: true, isSignedIn: false)

        // Catches: dropping `playbackController.stop()` from the genuine
        // sign-out arm. A presigned manifest URL stays valid for up to four
        // hours after it is minted, so AVQueuePlayer would keep streaming
        // role-gated archive audio while `RootView` swapped `MainView` for
        // `LoginView` -- taking the mini-player and the detail screen's Play
        // section with it, leaving no in-app transport to reach `stop()` with.
        #expect(deps.playbackController.currentItem == nil)
        #expect(engine.loads.last == [], "the engine's queue must be emptied, not merely paused")
    }

    @Test func coldLaunchSignedOutResolutionLeavesPlaybackAlone() async throws {
        let engine = SpyPlaybackEngine()
        let (deps, url) = Self.makeDeps(engine: engine)
        defer { Self.cleanup(url) }
        deps.playbackController.start(
            manifest: PlaybackFixtures.threeTrackManifest(),
            albumTitle: "DOGA",
            artistName: "Juana Molina"
        )

        // The cold-launch `.unknown` → `.signedOut` transition: nobody signed
        // out, so nothing should be torn down.
        await deps.handleAuthChange(wasSignedIn: false, isSignedIn: false)

        // Catches: hoisting `playbackController.stop()` out of the
        // `wasSignedIn` guard -- every launch would then stop whatever the
        // previous state had cued, and the sign-out test above would still
        // pass.
        #expect(deps.playbackController.currentItem != nil)
    }

    @Test func tapWhileSignedInPresentsImmediatelyWithCloneFallback() async throws {
        let (deps, url) = Self.makeDeps()
        defer { Self.cleanup(url) }
        try await #require(deps.catalogStore).replace(rows: [Self.dogaRow()], lastModified: nil)

        await deps.handleSpotlightTap(albumID: 100, isSignedIn: true)

        let presented = try #require(deps.router.deepLink)
        #expect(presented.id == 100)
        #expect(presented.route.fallback?.albumTitle == "DOGA")
        // The source rides the presentation, so the cover and the event name it.
        #expect(presented.source == .spotlight)
        #expect(deps.router.pending == nil)
    }

    @Test func tapWhileSignedInCloneMissRoutesWithNilFallback() async throws {
        let (deps, url) = Self.makeDeps()
        defer { Self.cleanup(url) }
        // Store openable but no row for this id — the clone-miss path.
        try await #require(deps.catalogStore).replace(rows: [Self.dogaRow(id: 100)], lastModified: nil)

        await deps.handleSpotlightTap(albumID: 999, isSignedIn: true)

        let presented = try #require(deps.router.deepLink)
        #expect(presented.id == 999)
        // No fallback — AlbumDetailView resolves the row by awaiting /library/info.
        #expect(presented.route.fallback == nil)
    }

    @Test func drainOnSignedInCloneMissReplaysWithNilFallback() async throws {
        let (deps, url) = Self.makeDeps()
        defer { Self.cleanup(url) }
        // A row exists, but not for the tapped id — the cold-launch replay's
        // clone-miss path (symmetry with the immediate-tap miss above).
        try await #require(deps.catalogStore).replace(rows: [Self.dogaRow(id: 100)], lastModified: nil)

        await deps.handleSpotlightTap(albumID: 999, isSignedIn: false)    // park a miss
        await deps.handleAuthChange(wasSignedIn: false, isSignedIn: true) // replay

        let presented = try #require(deps.router.deepLink)
        #expect(presented.id == 999)
        #expect(presented.route.fallback == nil)
        #expect(deps.router.pending == nil)
    }

    @Test func tapPresentsEvenWhenCatalogStoreIsInert() async throws {
        // A degraded device (disk unwritable) leaves catalogStore nil. The deep
        // link must still present — just without a clone fallback — so home-screen
        // search remains tappable; AlbumDetailView resolves via /library/info.
        let deps = AppDependencies(catalogStoreURL: nil)
        #expect(deps.catalogStore == nil)

        await deps.handleSpotlightTap(albumID: 100, isSignedIn: true)

        let presented = try #require(deps.router.deepLink)
        #expect(presented.id == 100)
        #expect(presented.route.fallback == nil)
    }

    @Test func signedInTapClearsAnEarlierStash() async throws {
        let (deps, url) = Self.makeDeps()
        defer { Self.cleanup(url) }
        try await #require(deps.catalogStore).replace(rows: [Self.dogaRow(id: 200)], lastModified: nil)

        await deps.handleSpotlightTap(albumID: 100, isSignedIn: false)  // park 100
        await deps.handleSpotlightTap(albumID: 200, isSignedIn: true)   // then a signed-in tap

        let presented = try #require(deps.router.deepLink)
        #expect(presented.id == 200)
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

    // MARK: - Issue #108: spotlight_deeplink_opened analytics

    @Test func immediateSignedInTapRecordsCloneHitAndNotParked() async throws {
        let analytics = SpyAnalytics()
        let (deps, url) = Self.makeDeps(analytics: analytics)
        defer { Self.cleanup(url) }
        try await #require(deps.catalogStore).replace(rows: [Self.dogaRow()], lastModified: nil)

        await deps.handleSpotlightTap(albumID: 100, isSignedIn: true)

        #expect(analytics.captures.count == 1)
        let capture = try #require(analytics.captures.first)
        #expect(capture.name == "spotlight_deeplink_opened")
        #expect(capture.properties["clone_hit"] == .bool(true))
        #expect(capture.properties["parked"] == .bool(false))
    }

    @Test func immediateSignedInTapCloneMissRecordsCloneHitFalse() async throws {
        let analytics = SpyAnalytics()
        let (deps, url) = Self.makeDeps(analytics: analytics)
        defer { Self.cleanup(url) }
        try await #require(deps.catalogStore).replace(rows: [Self.dogaRow(id: 100)], lastModified: nil)

        await deps.handleSpotlightTap(albumID: 999, isSignedIn: true)

        let capture = try #require(analytics.captures.first)
        #expect(capture.properties["clone_hit"] == .bool(false))
        #expect(capture.properties["parked"] == .bool(false))
    }

    @Test func replayedParkRecordsParkedTrue() async throws {
        let analytics = SpyAnalytics()
        let (deps, url) = Self.makeDeps(analytics: analytics)
        defer { Self.cleanup(url) }
        try await #require(deps.catalogStore).replace(rows: [Self.dogaRow()], lastModified: nil)

        await deps.handleSpotlightTap(albumID: 100, isSignedIn: false)  // parks, no event yet
        #expect(analytics.captures.isEmpty)
        await deps.handleAuthChange(wasSignedIn: false, isSignedIn: true)  // replays

        #expect(analytics.captures.count == 1)
        let capture = try #require(analytics.captures.first)
        #expect(capture.properties["clone_hit"] == .bool(true))
        #expect(capture.properties["parked"] == .bool(true))
    }

    /// Re-tapping the already-open cover early-outs before any resolve —
    /// no new deep link actually opened, so no second event.
    @Test func reTappingTheAlreadyOpenCoverRecordsNoSecondEvent() async throws {
        let analytics = SpyAnalytics()
        let (deps, url) = Self.makeDeps(analytics: analytics)
        defer { Self.cleanup(url) }
        try await #require(deps.catalogStore).replace(rows: [Self.dogaRow()], lastModified: nil)

        await deps.handleSpotlightTap(albumID: 100, isSignedIn: true)
        await deps.handleSpotlightTap(albumID: 100, isSignedIn: true)

        #expect(analytics.captures.count == 1)
    }

    // MARK: - Issue #126: swap the cover instead of refusing a second tap

    /// A tap for a *different* album while a cover is showing replaces the
    /// route directly. SwiftUI's `fullScreenCover(item:)` dismisses the old
    /// cover and presents the new one when the item's identity changes, so no
    /// queue or `onDismiss` drain is involved and nothing can strand.
    @Test func tapForADifferentAlbumWhileACoverIsOpenReplacesItDirectly() async throws {
        let analytics = SpyAnalytics()
        let (deps, url) = Self.makeDeps(analytics: analytics)
        defer { Self.cleanup(url) }
        try await #require(deps.catalogStore).replace(
            rows: [Self.dogaRow(id: 100), Self.dogaRow(id: 200)], lastModified: nil
        )

        await deps.handleSpotlightTap(albumID: 100, isSignedIn: true)
        await deps.handleSpotlightTap(albumID: 200, isSignedIn: true)

        #expect(deps.router.deepLink?.id == 200)
        #expect(deps.router.dismissal == nil)
        #expect(analytics.captures.count == 2)
        let second = try #require(analytics.captures.last)
        #expect(second.name == "spotlight_deeplink_opened")
        #expect(second.properties["parked"] == .bool(false))
    }

    /// The `onDismiss` SwiftUI fires for the replaced cover finds nothing held
    /// and leaves the new album up.
    @Test func theReplacedCoversDismissalLeavesTheNewAlbumUp() async throws {
        let (deps, url) = Self.makeDeps()
        defer { Self.cleanup(url) }
        try await #require(deps.catalogStore).replace(
            rows: [Self.dogaRow(id: 100), Self.dogaRow(id: 200)], lastModified: nil
        )

        await deps.handleSpotlightTap(albumID: 100, isSignedIn: true)
        await deps.handleSpotlightTap(albumID: 200, isSignedIn: true)
        await deps.deepLinkCoverDidDismiss()

        #expect(deps.router.deepLink?.id == 200)
    }

    /// A link arriving while the DJ's Close is still animating the cover out is
    /// held, not presented mid-dismissal, and the dismissal's `onDismiss`
    /// presents it.
    @Test func aLinkDuringTheDJsCloseWaitsForTheDismissal() async throws {
        let analytics = SpyAnalytics()
        let (deps, url) = Self.makeDeps(analytics: analytics)
        defer { Self.cleanup(url) }
        try await #require(deps.catalogStore).replace(
            rows: [Self.dogaRow(id: 100), Self.dogaRow(id: 200)], lastModified: nil
        )

        await deps.handleSpotlightTap(albumID: 100, isSignedIn: true)
        deps.closeDeepLinkCover()
        await deps.handleSpotlightTap(albumID: 200, isSignedIn: true)

        #expect(deps.router.deepLink == nil)
        #expect(deps.router.dismissal?.next == DeepLinkRequest(albumID: 200, source: .spotlight))
        #expect(analytics.captures.count == 1)

        await deps.deepLinkCoverDidDismiss()

        #expect(deps.router.deepLink?.id == 200)
        #expect(deps.router.dismissal == nil)
        #expect(analytics.captures.count == 2)
        #expect(analytics.captures.last?.properties["parked"] == .bool(false))
    }

    /// A newer link during the same Close replaces the held one.
    @Test func aNewerLinkDuringTheCloseReplacesTheHeldOne() async throws {
        let analytics = SpyAnalytics()
        let (deps, url) = Self.makeDeps(analytics: analytics)
        defer { Self.cleanup(url) }
        try await #require(deps.catalogStore).replace(
            rows: [Self.dogaRow(id: 100), Self.dogaRow(id: 200), Self.dogaRow(id: 300)], lastModified: nil
        )

        await deps.handleSpotlightTap(albumID: 100, isSignedIn: true)
        deps.closeDeepLinkCover()
        await deps.handleSpotlightTap(albumID: 200, isSignedIn: true)
        await deps.handleSpotlightTap(albumID: 300, isSignedIn: true)
        await deps.deepLinkCoverDidDismiss()

        #expect(deps.router.deepLink?.id == 300)
        #expect(analytics.captures.count == 2)  // A, then C; B was never shown
    }

    /// A resolve still in flight when the DJ taps Close is held when it lands,
    /// rather than writing a route into a cover that is animating out.
    @Test func aResolveInFlightWhenTheDJClosesIsHeldNotPresented() async throws {
        let store = GatedCatalogStore(rows: [Self.dogaRow(id: 100), Self.dogaRow(id: 200)])
        await store.release()
        let deps = AppDependencies(catalogStore: store)

        await deps.handleSpotlightTap(albumID: 100, isSignedIn: true)
        await store.hold()
        let tap = Task { await deps.handleSpotlightTap(albumID: 200, isSignedIn: true) }
        await store.waitUntilEntered(count: 1)
        deps.closeDeepLinkCover()
        await store.release()
        _ = await tap.value

        #expect(deps.router.deepLink == nil)
        #expect(deps.router.dismissal?.next?.albumID == 200)

        await deps.deepLinkCoverDidDismiss()

        #expect(deps.router.deepLink?.id == 200)
    }

    /// A parked replay held behind the DJ's Close keeps `parked: true` when the
    /// dismissal presents it.
    @Test func aHeldParkedReplayKeepsItsParkedFlag() async throws {
        let analytics = SpyAnalytics()
        let (deps, url) = Self.makeDeps(analytics: analytics)
        defer { Self.cleanup(url) }
        try await #require(deps.catalogStore).replace(
            rows: [Self.dogaRow(id: 100), Self.dogaRow(id: 200)], lastModified: nil
        )

        await deps.handleSpotlightTap(albumID: 100, isSignedIn: true)
        await deps.handleSpotlightTap(albumID: 200, isSignedIn: false)  // parked
        deps.closeDeepLinkCover()
        await deps.handleAuthChange(wasSignedIn: false, isSignedIn: true)
        await deps.deepLinkCoverDidDismiss()

        #expect(deps.router.deepLink?.id == 200)
        #expect(analytics.captures.last?.properties["parked"] == .bool(true))
    }

    /// A sign-out during the DJ's Close drops the held link: the dismissal it
    /// was waiting on presents nothing.
    @Test func signOutDuringTheCloseDropsTheHeldLink() async throws {
        let analytics = SpyAnalytics()
        let (deps, url) = Self.makeDeps(analytics: analytics)
        defer { Self.cleanup(url) }
        try await #require(deps.catalogStore).replace(
            rows: [Self.dogaRow(id: 100), Self.dogaRow(id: 200)], lastModified: nil
        )

        await deps.handleSpotlightTap(albumID: 100, isSignedIn: true)
        deps.closeDeepLinkCover()
        await deps.handleSpotlightTap(albumID: 200, isSignedIn: true)
        await deps.handleAuthChange(wasSignedIn: true, isSignedIn: false)
        await deps.deepLinkCoverDidDismiss()

        #expect(deps.router.deepLink == nil)
        #expect(deps.router.dismissal == nil)
        #expect(analytics.captures.count == 1)
    }

    /// The DJ closing a cover with nothing arriving is the ordinary dismissal.
    @Test func closingWithNothingHeldIsANoOp() async throws {
        let analytics = SpyAnalytics()
        let (deps, url) = Self.makeDeps(analytics: analytics)
        defer { Self.cleanup(url) }
        try await #require(deps.catalogStore).replace(rows: [Self.dogaRow()], lastModified: nil)

        await deps.handleSpotlightTap(albumID: 100, isSignedIn: true)
        deps.closeDeepLinkCover()
        await deps.deepLinkCoverDidDismiss()

        #expect(deps.router.deepLink == nil)
        #expect(deps.router.dismissal == nil)
        #expect(analytics.captures.count == 1)
    }

    /// A tap landing while the held link's resolve is still suspended wins,
    /// and the superseded resolve bows out without leaving the cover empty.
    @Test func aTapDuringTheDrainedResolveWinsWithoutStranding() async throws {
        let store = GatedCatalogStore(
            rows: [Self.dogaRow(id: 100), Self.dogaRow(id: 200), Self.dogaRow(id: 300)]
        )
        await store.release()
        let deps = AppDependencies(catalogStore: store)

        await deps.handleSpotlightTap(albumID: 100, isSignedIn: true)   // cover A up
        deps.closeDeepLinkCover()
        await deps.handleSpotlightTap(albumID: 200, isSignedIn: true)   // B held
        await store.hold()

        let drain = Task { await deps.deepLinkCoverDidDismiss() }       // present(B) suspends
        await store.waitUntilEntered(count: 1)
        let tap = Task { await deps.handleSpotlightTap(albumID: 300, isSignedIn: true) }
        await store.waitUntilEntered(count: 2)                          // present(C) suspends
        await store.release()
        _ = await drain.value
        _ = await tap.value

        #expect(deps.router.deepLink?.id == 300)
        #expect(deps.router.dismissal == nil)
    }

    // MARK: - Issue #186: wxycdj://album/<id> links from the listener app

    @Test func listenerAppLinkWhileSignedOutParksWithItsSourceAndReplays() async throws {
        let analytics = SpyAnalytics()
        let (deps, url) = Self.makeDeps(analytics: analytics)
        defer { Self.cleanup(url) }
        try await #require(deps.catalogStore).replace(rows: [Self.dogaRow()], lastModified: nil)

        await deps.handleDeepLink(albumID: 100, isSignedIn: false, source: .listenerApp)
        #expect(deps.router.pending == DeepLinkRequest(albumID: 100, source: .listenerApp))

        await deps.handleAuthChange(wasSignedIn: false, isSignedIn: true)

        let presented = try #require(deps.router.deepLink)
        #expect(presented.id == 100)
        #expect(presented.source == .listenerApp)
        let capture = try #require(analytics.captures.first)
        #expect(analytics.captures.count == 1)
        #expect(capture.name == "listener_app_link_opened")
        #expect(capture.properties["parked"] == .bool(true))
    }

    @Test func listenerAppLinkWhileSignedInPresentsWithItsSource() async throws {
        let analytics = SpyAnalytics()
        let (deps, url) = Self.makeDeps(analytics: analytics)
        defer { Self.cleanup(url) }
        try await #require(deps.catalogStore).replace(rows: [Self.dogaRow()], lastModified: nil)

        await deps.handleDeepLink(albumID: 100, isSignedIn: true, source: .listenerApp)

        let presented = try #require(deps.router.deepLink)
        #expect(presented.source == .listenerApp)
        #expect(presented.route.fallback?.albumTitle == "DOGA")
        let capture = try #require(analytics.captures.first)
        #expect(capture.name == "listener_app_link_opened")
        #expect(capture.properties["clone_hit"] == .bool(true))
        #expect(capture.properties["parked"] == .bool(false))
    }

    /// The feature's normal loop: open A from Spotlight (or an earlier link),
    /// then a link for B swaps the cover and records one listener-app event.
    @Test func listenerAppLinkForADifferentAlbumSwapsAnOpenSpotlightCover() async throws {
        let analytics = SpyAnalytics()
        let (deps, url) = Self.makeDeps(analytics: analytics)
        defer { Self.cleanup(url) }
        try await #require(deps.catalogStore).replace(
            rows: [Self.dogaRow(id: 100), Self.dogaRow(id: 200)], lastModified: nil
        )

        await deps.handleSpotlightTap(albumID: 100, isSignedIn: true)
        await deps.handleDeepLink(albumID: 200, isSignedIn: true, source: .listenerApp)

        let presented = try #require(deps.router.deepLink)
        #expect(presented.id == 200)
        #expect(presented.source == .listenerApp)
        #expect(analytics.captures.map(\.name) == ["spotlight_deeplink_opened", "listener_app_link_opened"])
        #expect(analytics.captures.last?.properties["parked"] == .bool(false))
    }

    /// A listener-app link for the album already open from Spotlight leaves
    /// the cover alone but still records the link: the button press worked
    /// and landed the DJ on its album, which is what the event counts.
    @Test func listenerAppLinkForTheAlbumAlreadyShowingRecordsTheLinkWithoutASwap() async throws {
        let analytics = SpyAnalytics()
        let (deps, url) = Self.makeDeps(analytics: analytics)
        defer { Self.cleanup(url) }
        try await #require(deps.catalogStore).replace(rows: [Self.dogaRow()], lastModified: nil)

        await deps.handleSpotlightTap(albumID: 100, isSignedIn: true)
        await deps.handleDeepLink(albumID: 100, isSignedIn: true, source: .listenerApp)

        #expect(deps.router.deepLink?.source == .spotlight)
        #expect(analytics.captures.map(\.name) == ["spotlight_deeplink_opened", "listener_app_link_opened"])
        #expect(analytics.captures.last?.properties["clone_hit"] == .bool(true))
    }

    /// A second link of the same source for the album already showing is a
    /// duplicate delivery or a re-tap: nothing changes and nothing is recorded.
    @Test func aSameSourceLinkForTheAlbumAlreadyShowingIsANoOp() async throws {
        let analytics = SpyAnalytics()
        let (deps, url) = Self.makeDeps(analytics: analytics)
        defer { Self.cleanup(url) }
        try await #require(deps.catalogStore).replace(rows: [Self.dogaRow()], lastModified: nil)

        await deps.handleDeepLink(albumID: 100, isSignedIn: true, source: .listenerApp)
        await deps.handleDeepLink(albumID: 100, isSignedIn: true, source: .listenerApp)

        #expect(analytics.captures.count == 1)
    }

    /// A URL the parser rejects never reaches the router.
    @Test func aMalformedListenerAppURLIsIgnored() async throws {
        let deps = AppDependencies(catalogStoreURL: nil)
        await deps.handleListenerAppURL(try #require(URL(string: "wxycdj://album/123?add=1")))
        #expect(deps.router.deepLink == nil)
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

    /// Block future `row(id:)` reads again, restarting the entered count, so a
    /// test can let a first presentation through and gate a later one.
    func hold() {
        released = false
        enteredCount = 0
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
