//
//  SearchViewModel.swift
//  WXYCDJTool
//
//  Owns the debounced library-search loop. Each keystroke (after ≥ 2 chars)
//  schedules a Task that sleeps 300 ms then issues GET /library/. Earlier
//  tasks are cancelled, matching dj-site's "newest query wins" behavior.
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
        case error(String)
    }

    var query: String = "" {
        didSet { onQueryChanged() }
    }

    private(set) var results: [AlbumSearchResult] = []
    private(set) var state: State = .idle

    private let api: APIClient
    private var searchTask: Task<Void, Never>?
    private static let minQueryLength = 2
    private static let debounce: Duration = .milliseconds(300)

    init(api: APIClient) {
        self.api = api
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
        do {
            // Pass the same query string to both artist_name and album_title.
            // GET /library/ ORs the two columns server-side (fuzzy match
            // either field), which matches dj-site's single-input search UX.
            let rows = try await api.searchLibrary(artist: q, title: q)
            if Task.isCancelled { return }
            results = rows
            state = rows.isEmpty ? .empty : .results
        } catch let error as APIError {
            if Task.isCancelled { return }
            state = .error(error.localizedMessage)
        } catch {
            if Task.isCancelled { return }
            state = .error(error.localizedDescription)
        }
    }

    func addToBin(_ row: AlbumSearchResult) async -> Bool {
        // When the row was surfaced by a track-title match (CTA fallback or
        // LML SONG_AS_TRACK proxy), preserve which track drove the match so
        // the bin entry remembers what the DJ was actually looking for.
        // Empty matchedVia (normal artist/album hit) passes nil through.
        do {
            _ = try await api.addToBin(albumId: row.id, trackTitle: row.matchedVia.first?.title)
            return true
        } catch {
            return false
        }
    }
}
