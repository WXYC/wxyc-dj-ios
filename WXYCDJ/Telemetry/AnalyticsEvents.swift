//
//  AnalyticsEvents.swift
//  WXYCDJ
//
//  Issue #108's wave-1 event catalog. Every event this app ever sends to
//  PostHog, and every property each one carries, lives in this one file --
//  so the app's whole data-collection surface is auditable in a single diff,
//  the same guarantee ADR 0007 holds for what Sentry never collects. Where a
//  capture decision is more than "fire here" (mapping a package error or an
//  outcome enum to an event), the mapping is a pure static function beside
//  the event it builds, so the decision stays unit-testable even at the
//  three capture sites (`AlbumDetailView`'s four events, `RootView`'s two
//  connectivity events) that have no test harness of their own -- see
//  CLAUDE.md's Telemetry section for exactly which sites those are and why.
//
//  Created by Jake Bromberg on 08/24/26.
//  Copyright © 2026 WXYC. All rights reserved.
//

import Foundation
import WXYCAPI

// MARK: - Sign-in (LoginViewModel)

/// Which credential a sign-in leg used. Shared by both sign-in events so
/// "otp vs. password" is one vocabulary, not two.
enum SignInMethod: String, CaseIterable, Sendable {
    case otp
    case password
}

/// Answers: is OTP-first sign-in (issue #100) working well enough that the
/// password form could eventually go?
struct SignInCompletedEvent: AnalyticsEvent {
    static let name = "sign_in_completed"
    let method: SignInMethod

    var properties: [String: AnalyticsPropertyValue] {
        ["method": .enumString(method)]
    }
}

/// The reason a sign-in leg failed, one case per ``WXYCAPI/AuthError`` case.
/// `init(_:)` is a **total switch with no `default:`** -- the same shape as
/// `AuthError.caseName` and `LoginViewModel.shouldReport(_:)` -- so a future
/// `AuthError` case is a compile-time decision about which reason bucket it
/// belongs in, not a silent gap.
enum SignInFailureReason: String, CaseIterable, Sendable {
    case invalidCredentials = "invalid_credentials"
    case rateLimited = "rate_limited"
    case rejected
    case server
    case missingSessionToken = "missing_session_token"
    case network
    case offline
    case notSignedIn = "not_signed_in"

    init(_ error: AuthError) {
        switch error {
        case .invalidCredentials: self = .invalidCredentials
        case .rateLimited: self = .rateLimited
        case .rejected: self = .rejected
        case .serverFailure: self = .server
        case .missingSessionToken: self = .missingSessionToken
        case .network: self = .network
        case .offline: self = .offline
        case .notSignedIn: self = .notSignedIn
        }
    }
}

/// Answers: where does sign-in friction come from -- e.g. shared-egress 429s
/// from the control room hitting the per-IP rate limiter?
struct SignInFailedEvent: AnalyticsEvent {
    static let name = "sign_in_failed"
    let method: SignInMethod
    let reason: SignInFailureReason

    var properties: [String: AnalyticsPropertyValue] {
        ["method": .enumString(method), "reason": .enumString(reason)]
    }
}

// MARK: - Search (SearchViewModel)

/// Which tier served a search -- mirrors `LibrarySearchOutcome.Source`
/// (issue #58), which has no `rawValue` of its own to reuse directly.
enum SearchSource: String, CaseIterable, Sendable {
    case server
    case local

    init(_ source: LibrarySearchOutcome.Source) {
        switch source {
        case .server: self = .server
        case .local: self = .local
        }
    }
}

/// Answers: how often does the on-device catalog clone actually serve a
/// search -- i.e. were issues #58 and #81 worth their complexity? Fires once
/// per **served** search (a debounced query that settles with results
/// rendered), not per keystroke -- see `SearchViewModel.performSearch(_:)`,
/// which returns before capturing when the debounce was cancelled.
struct SearchPerformedEvent: AnalyticsEvent {
    static let name = "search_performed"
    let source: SearchSource
    let resultCount: Int
    let queryLength: Int

    var properties: [String: AnalyticsPropertyValue] {
        [
            "source": .enumString(source),
            "result_count": .int(resultCount),
            "query_length": .int(queryLength),
        ]
    }
}

// MARK: - Album detail (AlbumDetailView)

/// How a DJ arrived at the detail screen. Threaded into `AlbumDetailView`'s
/// initializer by its three call sites (`SearchView`, `BinView`,
/// `DeepLinkAlbumCover`) so the event never has to guess.
enum AlbumDetailOrigin: String, CaseIterable, Sendable {
    case search
    case bin
    case spotlight
}

/// Answers: which releases do DJs actually look at, and does each surface
/// (search, bin, Spotlight) pull its weight?
struct AlbumDetailViewedEvent: AnalyticsEvent {
    static let name = "album_detail_viewed"
    let origin: AlbumDetailOrigin
    let albumId: Int

    var properties: [String: AnalyticsPropertyValue] {
        ["origin": .enumString(origin), "album_id": .int(albumId)]
    }
}

// MARK: - Bin (AlbumDetailView adds, BinViewModel removes)

/// Answers: bin feature adoption. The add button lives in the detail view
/// (`BinViewModel` only removes -- see `BinView`/`AlbumDetailView`), so this
/// event and ``BinItemRemovedEvent`` fire from two different files despite
/// naming the same feature.
struct BinItemAddedEvent: AnalyticsEvent {
    static let name = "bin_item_added"
    let albumId: Int

    var properties: [String: AnalyticsPropertyValue] {
        ["album_id": .int(albumId)]
    }
}

struct BinItemRemovedEvent: AnalyticsEvent {
    static let name = "bin_item_removed"
    let albumId: Int

    var properties: [String: AnalyticsPropertyValue] {
        ["album_id": .int(albumId)]
    }
}

// MARK: - Spotlight deep link (AppDependencies)

/// Answers: is the Spotlight index (issue #19 step 3, #36's delta-reindex
/// reshape) earning its complexity?
struct SpotlightDeeplinkOpenedEvent: AnalyticsEvent {
    static let name = "spotlight_deeplink_opened"
    /// Whether the on-device clone had a row for the tapped id, i.e. whether
    /// the header rendered instantly via `CatalogRow.detailFallback` rather
    /// than waiting on `/library/info`.
    let cloneHit: Bool
    /// Whether this presentation came from a tap that had to be parked
    /// (`Router.pending`, issue #19 step 7) and replayed once auth resolved,
    /// as opposed to an immediate signed-in tap.
    let parked: Bool

    var properties: [String: AnalyticsPropertyValue] {
        ["clone_hit": .bool(cloneHit), "parked": .bool(parked)]
    }
}

// MARK: - Catalog refresh (AppDependencies.refreshCatalog)

/// How `catalog_refresh_completed` learned about the run: `refreshCatalog()`
/// is called from three sites, each passing its own case.
enum CatalogRefreshTrigger: String, CaseIterable, Sendable {
    /// `WXYCDJApp`'s launch `.task`, after `restoreSession()`.
    case launch
    /// `WXYCDJApp`'s `.onChange(of: scenePhase)` on the `.active` case.
    case foreground
    /// `CatalogBackgroundTasks`'s reindex `BGProcessingTask` handler.
    case background
}

/// What the refresh did, as a closed vocabulary -- mirrors
/// `CatalogRefreshService.Outcome`'s three cases plus a fourth,
/// ``failed``, for the two catch arms (a genuine error, or
/// `APIError.offline`) that never produce an `Outcome` at all. The
/// `APIError.notSignedIn` skip is deliberately **not** representable here:
/// it isn't a refresh attempt (`refreshCatalog()` treats it as a no-op, not
/// a failure), so it emits no event, matching the error-reporting capture
/// site's identical carve-out.
enum CatalogRefreshOutcome: String, CaseIterable, Sendable {
    case refreshed
    case upToDate = "up_to_date"
    case skippedEmpty = "skipped_empty"
    case failed
}

/// Answers: is the on-device clone actually fresh, and do the background
/// tasks (issue #19 step 5) ever run on real devices? `rowCount`/`upserted`/
/// `removed` are 0 on every outcome but ``CatalogRefreshOutcome/refreshed``
/// -- there is nothing else to report on a `304`, an empty-export skip, or a
/// failure.
struct CatalogRefreshCompletedEvent: AnalyticsEvent {
    static let name = "catalog_refresh_completed"
    let outcome: CatalogRefreshOutcome
    let rowCount: Int
    let upserted: Int
    let removed: Int
    let trigger: CatalogRefreshTrigger

    var properties: [String: AnalyticsPropertyValue] {
        [
            "outcome": .enumString(outcome),
            "row_count": .int(rowCount),
            "upserted": .int(upserted),
            "removed": .int(removed),
            "trigger": .enumString(trigger),
        ]
    }

    /// Builds the event for a successful ``WXYCAPI/CatalogRefreshService/Outcome``
    /// -- the pure mapping `AppDependencies.refreshCatalog()` calls on its
    /// success path, kept beside the event it builds so the case-by-case
    /// mapping is unit-testable without a network round trip.
    static func from(outcome: CatalogRefreshService.Outcome, trigger: CatalogRefreshTrigger) -> Self {
        switch outcome {
        case .upToDate:
            Self(outcome: .upToDate, rowCount: 0, upserted: 0, removed: 0, trigger: trigger)
        case .refreshed(let rowCount, let upserted, let removed):
            Self(outcome: .refreshed, rowCount: rowCount, upserted: upserted, removed: removed, trigger: trigger)
        case .skippedEmptyExport:
            Self(outcome: .skippedEmpty, rowCount: 0, upserted: 0, removed: 0, trigger: trigger)
        }
    }

    /// The event for a failed refresh attempt (a genuine error, or
    /// `APIError.offline`) -- there is no `Outcome` to map, so this is a
    /// plain constructor rather than a second `from`.
    static func failed(trigger: CatalogRefreshTrigger) -> Self {
        Self(outcome: .failed, rowCount: 0, upserted: 0, removed: 0, trigger: trigger)
    }
}

// MARK: - LML enrichment (AlbumDetailView.loadMetadata)

/// Why `/proxy/metadata/album` (LML) enrichment came back empty, as a closed
/// vocabulary derived from ``WXYCAPI/APIError``. `init?(_:)` is a total
/// switch mirroring `AlbumDetailView.shouldReportMetadataFailure(_:)` --
/// every `APIError` case is listed exactly once, so a new case is a
/// compile-time decision about which (if any) kind it maps to. Returns
/// `nil` for every case that isn't a genuine "LML has nothing for this"
/// signal: `.unauthorized`/`.notSignedIn` are session states, `.network`/
/// `.offline` are transport-layer (not enrichment-coverage) facts, and an
/// `.http` status outside 404/429 is too varied to bucket honestly.
enum MetadataEnrichmentMissingKind: String, CaseIterable, Sendable {
    case notFound = "not_found"
    case rateLimited = "rate_limited"
    case decodeFailed = "decode_failed"

    init?(_ error: APIError) {
        switch error {
        case .decoding:
            self = .decodeFailed
        case .http(let status, _) where status == 404:
            self = .notFound
        case .http(let status, _) where status == 429:
            self = .rateLimited
        case .http, .unauthorized, .notSignedIn, .network, .offline:
            return nil
        }
    }
}

/// Answers: how often does LML enrichment miss, and on what kind of gap --
/// signal for upstream library-metadata-lookup tickets.
struct MetadataEnrichmentMissingEvent: AnalyticsEvent {
    static let name = "metadata_enrichment_missing"
    let kind: MetadataEnrichmentMissingKind

    var properties: [String: AnalyticsPropertyValue] {
        ["kind": .enumString(kind)]
    }
}

// MARK: - Artwork retirement (AlbumDetailView header AsyncImage)

/// Which catalog/LML source's artwork URL was retired, mirroring the
/// precedence `AlbumDetailView.preferredArtworkURL` walks: `/library/info`,
/// the live search-row fallback, the on-device clone, LML metadata.
enum ArtworkRetiredSource: String, CaseIterable, Sendable {
    case info
    case searchRow = "search_row"
    case clone
    case lml
}

/// Answers: how often does a dead pre-signed CDN URL (an expired signature,
/// a purged asset -- issue #86) actually show up in the field?
struct ArtworkURLRetiredEvent: AnalyticsEvent {
    static let name = "artwork_url_retired"
    let source: ArtworkRetiredSource

    var properties: [String: AnalyticsPropertyValue] {
        ["source": .enumString(source)]
    }
}

// MARK: - Connectivity (RootView)

/// Answers: station network health, and whether issue #81's half-open probe
/// is doing its job. No properties -- the edge itself is the whole signal.
/// Fires from `RootView.body`'s `.onChange(of: connectivity.isOnline)`, not
/// from `ConnectivityMonitor.reconnects` (a single-consumer stream #61's
/// queued-bin flush is documented to claim) -- see CLAUDE.md's Telemetry
/// section for the full argument.
struct OfflineLatchEngagedEvent: AnalyticsEvent {
    static let name = "offline_latch_engaged"
    var properties: [String: AnalyticsPropertyValue] { [:] }
}

struct ConnectivityRestoredEvent: AnalyticsEvent {
    static let name = "connectivity_restored"
    var properties: [String: AnalyticsPropertyValue] { [:] }
}

/// Classifies an `isOnline` transition, or `nil` for a same-value
/// "transition" (`.onChange` firing with an unchanged value isn't possible
/// in SwiftUI, but a direct test of this function shouldn't assume that).
///
/// A closed enum rather than returning `any AnalyticsEvent` directly: `Analytics
/// .capture(_:)` takes `some AnalyticsEvent` (an opaque/generic parameter, per
/// this file's header), which an existential `any AnalyticsEvent` value does
/// **not** satisfy -- `AnalyticsEvent` has no compiler-blessed self-conformance,
/// so `deps.analytics.capture(existentialValue)` fails to type-check. Returning
/// this enum instead and letting the caller switch into the concrete
/// ``OfflineLatchEngagedEvent``/``ConnectivityRestoredEvent`` sidesteps that
/// entirely, while keeping the *decision* -- which edge, if any, fired -- pure
/// and unit-testable independent of `RootView`'s otherwise-untestable
/// `.onChange` wiring, the same shape `shouldReportMetadataFailure` gives
/// `AlbumDetailView`.
enum ConnectivityTransition: Sendable, Equatable {
    case engaged
    case restored

    static func classify(wasOnline: Bool, isOnline: Bool) -> ConnectivityTransition? {
        if wasOnline, !isOnline { return .engaged }
        if !wasOnline, isOnline { return .restored }
        return nil
    }
}
