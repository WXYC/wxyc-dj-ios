//
//  LibrarySearch.swift
//  WXYCAPI
//
//  Online-first / offline-fallback library search router (issue #58). When the
//  app believes it is online it asks the server (byte-for-byte the same call the
//  UI made before); on a failed request, or when the ConnectivityMonitor reports
//  offline, it searches the on-device catalog clone's FTS index instead. The
//  outcome carries which tier served the results so the UI can frame local hits.
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
/// - **offline** → go straight to local (no network round-trip).
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
        return await localOutcome(query: query, limit: limit)
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
