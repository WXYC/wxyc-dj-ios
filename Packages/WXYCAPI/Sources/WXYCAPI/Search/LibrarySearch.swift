//
//  LibrarySearch.swift
//  WXYCAPI
//
//  Online-first / offline-fallback library search router (issue #58). When the
//  app believes it is online it asks the server (byte-for-byte the same call the
//  UI made before); on a failed request, or when the ConnectivityMonitor reports
//  offline, it searches the on-device catalog clone's FTS index instead. The
//  outcome carries which tier served the results so the UI can frame local hits.
//  Issue #81: an offline search past the connectivity monitor's half-open
//  cooldown also fires a fire-and-forget probe at the server so a latched
//  monitor can self-recover through the surface the DJ is actually using.
//
//  Created by Jake on 06/28/26.
//  Copyright © 2026 WXYC. All rights reserved.
//

import Foundation

/// The result of a ``LibrarySearch/search(query:limit:)``, plus which tier
/// produced it so the UI can quietly mark offline (`.local`) results.
public struct LibrarySearchOutcome: Sendable, Equatable {
    /// Which tier served the results.
    public enum Source: Sendable, Equatable {
        /// Live `GET /library/` — fuzzy ranking + track-title hints, identical
        /// to the online-only behavior.
        case server
        /// The on-device catalog clone's FTS index (artist/album/call number).
        case local
    }

    public let results: [AlbumSearchResult]
    public let source: Source

    public init(results: [AlbumSearchResult], source: Source) {
        self.results = results
        self.source = source
    }
}

/// Routes a library search to the server or the on-device clone.
///
/// `@MainActor` because it reads the `@MainActor` ``ConnectivityMonitor`` and is
/// driven by the `@MainActor` search view model. The routing is:
///
/// - **online** → try the server; on *any* thrown error fall back to local.
/// - **offline, half-open** → ``ConnectivityMonitor/consumeProbe()`` claims the
///   cooldown's one allowance: fire a real server request in the background
///   (issue #81), then go straight to local without waiting on it.
/// - **offline, otherwise** → go straight to local (no network round-trip).
/// - **local** → ``CatalogStore/search(query:limit:)``, each cloned row bridged
///   to an `AlbumSearchResult` via ``CatalogRow/detailFallback``.
///
/// A `nil` `catalogStore` (a device that couldn't open the clone) makes the
/// router effectively server-only: there's nothing to fall back to, so a failed
/// or offline search yields an empty `.local` result.
@MainActor
public struct LibrarySearch {
    private let api: APIClient
    private let catalogStore: (any CatalogStore)?
    private let connectivity: ConnectivityMonitor

    public init(api: APIClient, catalogStore: (any CatalogStore)?, connectivity: ConnectivityMonitor) {
        self.api = api
        self.catalogStore = catalogStore
        self.connectivity = connectivity
    }

    /// Search the library, preferring the live server and falling back to the
    /// on-device clone. Never throws — a failed online request degrades to the
    /// local index automatically (no manual retry), and an empty/missing clone
    /// simply returns no results.
    public func search(query: String, limit: Int = 25) async -> LibrarySearchOutcome {
        if connectivity.isOnline {
            do {
                // Pass the query to both artist_name and album_title, exactly as
                // the online-only path did, so server behavior is unchanged.
                let rows = try await api.searchLibrary(artist: query, title: query, limit: limit)
                return LibrarySearchOutcome(results: rows, source: .server)
            } catch {
                return await localOutcome(query: query, limit: limit)
            }
        }
        // Latched offline. If the monitor's half-open cooldown has elapsed,
        // claim its one allowance and fire a real probe in the background
        // (issue #81) — but this search's own results still come from the
        // clone; see fireHalfOpenProbe's doc for why.
        if connectivity.consumeProbe() {
            fireHalfOpenProbe(query: query, limit: limit)
        }
        return await localOutcome(query: query, limit: limit)
    }

    /// Fire-and-forget half-open probe (issue #81): a real `searchLibrary` hit
    /// for the same query, launched without being awaited so a slow or failed
    /// probe never delays the local results this search already has ready —
    /// the offline-first ergonomics of #58 stay intact. Its result is
    /// discarded on purpose; the probe exists to produce a **connectivity
    /// signal**, not to serve this particular search (the local branch already
    /// covers that). The signal itself needs no extra plumbing: `APIClient.fire`
    /// reports every transport outcome through the same hook a foreground
    /// request would (`onOutcome` → `ConnectivityMonitor.ingest(isOnline:)`), so
    /// a transport success un-latches the monitor and fires the reconnect edge,
    /// and a transport failure moves `ConnectivityMonitor`'s cooldown anchor
    /// forward, restarting the wait for the next allowed probe.
    ///
    /// Some throws produce **no** outcome at all — `APIClient.perform` resolves
    /// a bearer token before it touches the network, and the `fire` cancellation
    /// carve-out reports nothing by design — so the monitor deliberately expires
    /// a claim on time rather than on an outcome; a silent probe costs one
    /// cooldown. See `ConnectivityMonitor.cooldownAnchor`.
    ///
    /// The `Task` is **unstructured on purpose**: it must outlive this search.
    /// `SearchViewModel`'s debounce cancels its in-flight search task on every
    /// keystroke, and a child task would be torn down with it — the probe would
    /// then be cancelled before it reached the server, which (per the #58
    /// carve-out) reports nothing, so the DJ could type their way past every
    /// cooldown without a single real attempt ever completing. `Task.init`
    /// inherits actor isolation and priority but **not** cancellation, and
    /// nothing retains the handle, so the probe always runs to completion.
    private func fireHalfOpenProbe(query: String, limit: Int) {
        let api = self.api
        Task {
            _ = try? await api.searchLibrary(artist: query, title: query, limit: limit)
        }
    }

    /// Resolve the local fallback: search the clone (a missing store or a thrown
    /// read collapses to no results) and bridge each row to a result. Always
    /// reports `.local` so the UI can frame it as the saved library.
    private func localOutcome(query: String, limit: Int) async -> LibrarySearchOutcome {
        guard let catalogStore else {
            return LibrarySearchOutcome(results: [], source: .local)
        }
        let rows = (try? await catalogStore.search(query: query, limit: limit)) ?? []
        return LibrarySearchOutcome(results: rows.map(\.detailFallback), source: .local)
    }
}
