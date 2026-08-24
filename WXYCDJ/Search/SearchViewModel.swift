//
//  SearchViewModel.swift
//  WXYCDJ
//
//  Owns the debounced library-search loop. Each keystroke (after ≥ 2 chars)
//  schedules a Task that sleeps 300 ms then runs a LibrarySearch — online-first,
//  with an automatic on-device fallback when offline or when the request fails
//  (issue #58). Earlier tasks are cancelled, matching dj-site's "newest query
//  wins" behavior.
//
//  Created by Jake on 5/14/26.
//  Copyright © 2026 WXYC. All rights reserved.
//

import Foundation
import Observation
import WXYCAPI

@MainActor
@Observable
final class SearchViewModel {
    enum State: Sendable, Equatable {
        case idle
        case searching
        case results
        case empty
    }

    var query: String = "" {
        didSet { onQueryChanged() }
    }

    private(set) var results: [AlbumSearchResult] = []
    private(set) var state: State = .idle
    /// Which tier served the current `results` — `.server` for live search,
    /// `.local` for the offline FTS fallback (issue #58). The view reads this in
    /// the `.results` state to show a quiet "Showing saved library" note when
    /// results came from the on-device clone.
    private(set) var source: LibrarySearchOutcome.Source = .server

    private let search: LibrarySearch
    private let api: APIClient
    /// The app's product-analytics seam (issue #108). Defaults to
    /// ``NoOpAnalytics`` so every existing construction site keeps compiling
    /// unchanged; `SearchView` passes `deps.analytics`.
    private let analytics: any Analytics
    private var searchTask: Task<Void, Never>?
    private static let minQueryLength = 2
    private static let debounce: Duration = .milliseconds(300)

    init(search: LibrarySearch, api: APIClient, analytics: any Analytics = NoOpAnalytics()) {
        self.search = search
        self.api = api
        self.analytics = analytics
    }

    private func onQueryChanged() {
        searchTask?.cancel()
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= Self.minQueryLength else {
            results = []
            state = .idle
            return
        }
        state = .searching
        searchTask = Task {
            try? await Task.sleep(for: Self.debounce)
            if Task.isCancelled { return }
            await performSearch(trimmed)
        }
    }

    private func performSearch(_ q: String) async {
        // LibrarySearch never throws: a failed online request or an offline
        // monitor degrades to the on-device clone automatically. The outcome
        // carries which tier served it so the UI can frame local results.
        let outcome = await search.search(query: q)
        // A debounce-cancelled search (a keystroke superseded this one before
        // the request settled) captures nothing (issue #108) — the DJ never
        // saw these results, so they're not a served search.
        if Task.isCancelled { return }
        results = outcome.results
        source = outcome.source
        state = outcome.results.isEmpty ? .empty : .results
        analytics.capture(SearchPerformedEvent(
            source: SearchSource(outcome.source),
            resultCount: outcome.results.count,
            queryLength: q.count
        ))
    }

    func addToBin(_ row: AlbumSearchResult) async -> Bool {
        // When the row was surfaced by a track-title match (CTA fallback or
        // LML SONG_AS_TRACK proxy), preserve which track drove the match so
        // the bin entry remembers what the DJ was actually looking for.
        // Empty matchedVia (normal artist/album hit) passes nil through.
        do {
            try await api.addToBin(albumId: row.id, trackTitle: row.matchedVia.first?.title)
            // Issue #108: bin adoption. This is the *other* add button --
            // `AlbumDetailView.addToBin()` is the one on the release screen.
            // Instrumenting only that one would answer "bin adoption" from a
            // biased sample and leave `bin_item_removed` events with no
            // matching add, since a DJ can add straight from the results list
            // without ever opening the detail view.
            analytics.capture(BinItemAddedEvent(albumId: row.id))
            return true
        } catch {
            return false
        }
    }
}
