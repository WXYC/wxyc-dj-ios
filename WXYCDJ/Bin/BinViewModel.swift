//
//  BinViewModel.swift
//  WXYCDJ
//
//  Owns the local cache of GET /djs/bin and exposes refresh + remove. Backed by
//  an optional offline snapshot store (issue #60): a cold launch loads the
//  persisted snapshot first so the bin renders without connectivity, and every
//  successful online refresh writes the snapshot back.
//
//  Created by Jake on 5/14/26.
//  Copyright © 2026 WXYC. All rights reserved.
//

import Foundation
import Observation
import WXYCAPI

@MainActor
@Observable
final class BinViewModel {
    enum State: Sendable, Equatable {
        case loading
        case loaded
        case error(String)
    }

    private(set) var entries: [BinEntry] = []
    private(set) var state: State = .loading
    /// Surfaced as an alert by BinView. `state` is reserved for the
    /// initial-load lifecycle (loading / loaded / error); a remove failure
    /// against an already-loaded list shouldn't blow the list away.
    var removeError: String?

    private let api: APIClient
    /// Persists the last server snapshot so the bin reads offline (issue #60).
    /// `nil` when the SQLite store couldn't be opened — the view model then
    /// behaves exactly as before (online-only).
    private let binStore: (any BinStore)?

    init(api: APIClient, binStore: (any BinStore)? = nil) {
        self.api = api
        self.binStore = binStore
    }

    /// Cold-launch step: populate `entries` from the persisted snapshot **before**
    /// the network refresh, so an offline bin renders immediately rather than
    /// waiting on (and being gated by) a failing request. A non-empty snapshot
    /// flips `state` to `.loaded`; a never-written store (`snapshot() == nil`) or
    /// a read error leaves `state` at `.loading` for `refresh()` to resolve. Best
    /// effort — never throws, never surfaces an error.
    func loadSnapshot() async {
        guard let binStore else { return }
        do {
            guard let snapshot = try await binStore.snapshot() else { return }
            entries = snapshot.sorted { $0.addedAt > $1.addedAt }
            if !entries.isEmpty {
                state = .loaded
            }
        } catch {
            // A failed snapshot read is non-fatal: leave state for refresh().
        }
    }

    func refresh() async {
        state = .loading
        do {
            let response = try await api.getBin()
            entries = response.entries.sorted { $0.addedAt > $1.addedAt }
            state = .loaded
            // Persist the fresh server truth for the next offline launch. A write
            // failure must not turn a successful refresh into an error.
            try? await binStore?.saveSnapshot(response.entries)
        } catch let error as APIError {
            handleRefreshFailure(error.localizedMessage)
        } catch {
            handleRefreshFailure(error.localizedDescription)
        }
    }

    /// On a refresh failure, keep an already-populated list (loaded from the
    /// offline snapshot) visible — only surface `.error` when there's nothing to
    /// show. Never blows a good snapshot away.
    private func handleRefreshFailure(_ message: String) {
        state = entries.isEmpty ? .error(message) : .loaded
    }

    func remove(_ entry: BinEntry) async {
        do {
            try await api.removeFromBin(albumId: entry.albumId, trackTitle: nil)
            entries.removeAll { $0.id == entry.id }
        } catch {
            removeError = (error as? APIError)?.localizedMessage ?? error.localizedDescription
        }
    }
}
