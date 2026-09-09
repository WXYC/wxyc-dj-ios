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
enum SignInMethod: String, AnalyticsEnum {
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
enum SignInFailureReason: String, AnalyticsEnum {
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
enum SearchSource: String, AnalyticsEnum {
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
enum AlbumDetailOrigin: String, AnalyticsEnum {
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

/// Answers: bin feature adoption. There are **two** add buttons and one
/// remove button, so this event and ``BinItemRemovedEvent`` fire from three
/// different files despite naming the same feature: a DJ can add from the
/// search results list (`SearchResultRow`'s button →
/// `SearchViewModel.addToBin(_:)`) or from the release detail screen
/// (`AlbumDetailView.addToBin()`), and can only remove from the bin tab
/// (`BinViewModel.remove(_:)`). Instrumenting only the detail-view add --
/// which an earlier draft of this comment wrongly described as the only one --
/// would answer "adoption" from a biased sample and produce
/// ``BinItemRemovedEvent``s with no matching add.
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

// MARK: - Catalog refresh (AppDependencies.refreshCatalog / .handleBackgroundPoll)

/// How `catalog_refresh_completed` learned about the run: `refreshCatalog()`
/// is called from three sites, each passing its own case, plus a fourth
/// site that isn't a `refreshCatalog()` call at all.
enum CatalogRefreshTrigger: String, AnalyticsEnum {
    /// `WXYCDJApp`'s launch `.task`, after `restoreSession()`.
    case launch
    /// `WXYCDJApp`'s `.onChange(of: scenePhase)`, on a **genuine** `.active`
    /// re-entry -- not the cold-launch activation, which `.launch` already
    /// covers (issue #118 item 4: `ForegroundReentryTracker` is what tells
    /// the two apart).
    case foreground
    /// `CatalogBackgroundTasks`'s reindex `BGProcessingTask` handler, via
    /// `refreshCatalog()`.
    case background
    /// `AppDependencies.handleBackgroundPoll()` -- the `BGAppRefreshTask`
    /// poll leg (issue #118 item 3). Not a `refreshCatalog()` call: `poll()`
    /// only asks "did the catalog move," so its event is built by
    /// ``CatalogRefreshCompletedEvent/poll(changed:trigger:)``, not `.from`.
    /// Before this case, the poll leg had **no** analytics signal at all --
    /// `requiresExternalPower` on the reindex `BGProcessingTask` and the
    /// 200-only submission gate meant a device that never charges, or whose
    /// catalog never changed, reported zero `.background` events, which read
    /// identically to "the background tasks never ran."
    case backgroundPoll = "background_poll"
}

/// What the refresh did, as a closed vocabulary -- mirrors
/// `CatalogRefreshService.Outcome`'s three cases plus ``failed``, for the
/// two catch arms (a genuine error, or `APIError.offline`) that never
/// produce an `Outcome` at all; ``pollChanged``, for a `.backgroundPoll`
/// conditional GET that found the catalog moved (the reindex itself is
/// deferred to a later `.background`-triggered `refreshCatalog()`, so there
/// are no row counts to report yet); ``pollSkipped``, for a `.backgroundPoll`
/// that made **no request at all** because a `refresh()` was already in
/// flight (issue #118 review -- deliberately its own case rather than
/// `.upToDate`, since the app learned nothing about whether the catalog
/// moved, and saying otherwise is the same null-answer bias item 3 removes);
/// and ``noStore``, for a refresh or poll with no `catalogRefreshService` at
/// all (the SQLite store never opened) -- previously indistinguishable from
/// "never attempted" since that branch recorded nothing. The
/// `APIError.notSignedIn` skip is
/// deliberately **not** representable here: it isn't a refresh attempt
/// (`refreshCatalog()` treats it as a no-op, not a failure), so it emits no
/// event, matching the error-reporting capture site's identical carve-out.
enum CatalogRefreshOutcome: String, AnalyticsEnum {
    case refreshed
    case upToDate = "up_to_date"
    case skippedEmpty = "skipped_empty"
    case failed
    case pollChanged = "poll_changed"
    case pollSkipped = "poll_skipped"
    case noStore = "no_store"
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

    /// The event `AppDependencies.handleBackgroundPoll()` builds from
    /// `CatalogRefreshService.PollOutcome` (issue #118 item 3) -- `poll()` has
    /// no `Outcome` to map (it never replaces the store or reindexes), so
    /// whether the catalog moved is the only fact there is to report.
    ///
    /// A **total switch with no `default:`**, the same shape as `from` above:
    /// `PollOutcome` gaining a case has to be a decision made here. In
    /// particular ``CatalogRefreshOutcome/pollSkipped`` is deliberately not
    /// folded into `.upToDate` (issue #118 review) -- a poll that
    /// short-circuited on an in-flight refresh made no request at all, so
    /// reporting it as "the catalog didn't move" would assert something the
    /// app never learned, which is the same null-answer bias item 3 exists to
    /// remove.
    static func poll(outcome: CatalogRefreshService.PollOutcome, trigger: CatalogRefreshTrigger) -> Self {
        let mapped: CatalogRefreshOutcome = switch outcome {
        case .changed: .pollChanged
        case .unchanged: .upToDate
        case .skippedRefreshInFlight: .pollSkipped
        }
        return Self(outcome: mapped, rowCount: 0, upserted: 0, removed: 0, trigger: trigger)
    }

    /// The event for a `refreshCatalog()` call with no `catalogRefreshService`
    /// at all -- the SQLite store never opened (issue #118's "also worth a
    /// sentence": `AppDependencies.init`'s degrade path leaves this metric
    /// unable to tell a broken store from a device that simply never
    /// refreshed).
    static func noStore(trigger: CatalogRefreshTrigger) -> Self {
        Self(outcome: .noStore, rowCount: 0, upserted: 0, removed: 0, trigger: trigger)
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
///
/// ``missingArtistName`` is the one case with no `APIError` behind it at
/// all: `AlbumDetailView.loadMetadata`'s `guard let artistName` early return
/// (a Spotlight deep link whose clone-miss `/library/info` also came back
/// with nothing to key an LML lookup on) is a genuine enrichment gap that
/// never reaches the network, so it never reached this switch -- issue
/// #118's "also worth a sentence": that gap was invisible to this event
/// entirely. Constructed directly at that call site, not through `init?(_:)`.
enum MetadataEnrichmentMissingKind: String, AnalyticsEnum {
    case notFound = "not_found"
    case rateLimited = "rate_limited"
    case decodeFailed = "decode_failed"
    case missingArtistName = "missing_artist_name"

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
enum ArtworkRetiredSource: String, AnalyticsEnum {
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
/// A closed `Equatable` enum so the *decision* -- which edge, if any, fired --
/// stays pure and unit-testable independently of `RootView`'s otherwise
/// untestable `.onChange` wiring, the same shape `shouldReportMetadataFailure`
/// gives `AlbumDetailView`. ``event`` then does the mapping here, in the file
/// that owns the events and is covered by the catalog suite, rather than in a
/// switch at the untested call site.
enum ConnectivityTransition: Sendable, Equatable {
    case engaged
    case restored

    static func classify(wasOnline: Bool, isOnline: Bool) -> ConnectivityTransition? {
        guard wasOnline != isOnline else { return nil }
        return isOnline ? .restored : .engaged
    }

    /// The event this edge records. Returning `any AnalyticsEvent` is fine
    /// even though `Analytics.capture(_:)` takes `some AnalyticsEvent`: Swift's
    /// implicit existential opening (SE-0352) opens the existential at the call
    /// site, so `analytics.capture(transition.event)` type-checks. (An earlier
    /// version of this comment claimed it did not, and made the caller switch
    /// into the concrete type; that claim was false -- verified by compiling
    /// both forms under `-swift-version 6`.)
    var event: any AnalyticsEvent {
        switch self {
        case .engaged: OfflineLatchEngagedEvent()
        case .restored: ConnectivityRestoredEvent()
        }
    }
}
