//
//  BinViewModel.swift
//  WXYCDJ
//
//  Owns the local cache of GET /djs/bin (a bare array of denormalized library
//  rows) and exposes refresh + remove, sorted into shelf order. Backed by
//  an optional offline snapshot store (issue #60): a cold launch loads the
//  persisted snapshot first so the bin renders without connectivity, and every
//  successful online refresh writes the snapshot back.
//
//  Created by Jake on 5/14/26.
//  Copyright © 2026 WXYC. All rights reserved.
//

import Foundation
import Observation
import OSLog
import WXYCAPI

private let binLog = Logger(subsystem: "org.wxyc.dj", category: "bin")

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
    /// True once `entries` reflects an *authoritative* bin — a persisted snapshot
    /// (even an empty one) or a successful server load — as opposed to "not loaded
    /// yet". This is what consumes the store's never-written-`nil` vs written-
    /// empty-`[]` distinction (issue #60): a present-but-empty bin is authoritative
    /// emptiness ("Bin is empty"), so an offline refresh failure on it shows the
    /// empty tray rather than regressing to "Couldn't load bin".
    private var hasLoadedBin = false

    init(api: APIClient, binStore: (any BinStore)? = nil) {
        self.api = api
        self.binStore = binStore
    }

    /// Cold-launch step: populate `entries` from the persisted snapshot **before**
    /// the network refresh, so an offline bin renders immediately rather than
    /// waiting on (and being gated by) a failing request. A present snapshot —
    /// including a written-but-empty one (`snapshot() == []`) — flips `state` to
    /// `.loaded` (the empty case renders the "Bin is empty" tray, not a spinner).
    /// A never-written store (`snapshot() == nil`) or a read error leaves `state`
    /// at `.loading` for `refresh()` to resolve. Best effort — never throws, never
    /// surfaces an error.
    func loadSnapshot() async {
        guard let binStore else { return }
        do {
            guard let snapshot = try await binStore.snapshot() else { return }
            entries = Self.normalized(snapshot)
            hasLoadedBin = true
            state = .loaded
        } catch {
            // A failed snapshot read is non-fatal: leave state for refresh().
        }
    }

    func refresh() async {
        // Only show the full-screen spinner when there's nothing authoritative to
        // display yet. A loaded snapshot (even an empty one) stays on screen while
        // the network refresh runs; `.refreshable` drives its own indicator.
        if !hasLoadedBin {
            state = .loading
        }
        do {
            let normalized = Self.normalized(try await api.getBin())
            entries = normalized
            hasLoadedBin = true
            state = .loaded
            // Persist the fresh server truth for the next offline launch. A write
            // failure must not turn a successful refresh into an error — but log it,
            // since a silently stale offline bin is otherwise invisible to debug.
            // The *normalized* list is what's persisted: the store is keyed by
            // album id, so a duplicate would fail the whole save.
            do {
                try await binStore?.saveSnapshot(normalized)
            } catch {
                binLog.error("Bin snapshot save failed: \(error.localizedDescription, privacy: .public). Offline bin may be stale.")
            }
        } catch let error as APIError {
            handleRefreshFailure(error.localizedMessage)
        } catch {
            handleRefreshFailure(error.localizedDescription)
        }
    }

    /// On a refresh failure, keep an authoritative bin (a loaded snapshot or a
    /// prior successful load) on screen — even a known-empty one — and only
    /// surface `.error` when there's genuinely nothing loaded. Never blows a good
    /// snapshot away.
    private func handleRefreshFailure(_ message: String) {
        state = hasLoadedBin ? .loaded : .error(message)
    }

    /// Shelf order for the bin: the artist's filing name, then album title.
    /// `GET /djs/bin` has no ORDER BY and carries no added-at column, so server
    /// order is arbitrary and unstable across refreshes — sorting here is what
    /// keeps rows from reshuffling under the DJ. The dedupe collapses the
    /// repeated projection of an album binned under two track titles: the wire
    /// rows are identical (no `track_title` in the projection) and
    /// `DELETE /djs/bin` clears the album wholesale, so they're one row here.
    private static func normalized(_ entries: [BinEntry]) -> [BinEntry] {
        var seen: Set<Int> = []
        return entries
            .filter { seen.insert($0.albumId).inserted }
            .sorted { lhs, rhs in
                switch lhs.sortName.localizedStandardCompare(rhs.sortName) {
                case .orderedAscending: true
                case .orderedDescending: false
                case .orderedSame: lhs.albumTitle.localizedStandardCompare(rhs.albumTitle) == .orderedAscending
                }
            }
    }

    func remove(_ entry: BinEntry) async {
        do {
            try await api.removeFromBin(albumId: entry.albumId, trackTitle: nil)
            entries.removeAll { $0.id == entry.id }
            // Mirror the removal into the snapshot. Without this the persisted
            // bin still holds the release, so "remove → relaunch" resurrects it
            // via loadSnapshot() until a network refresh lands — indefinitely
            // while offline, which is exactly the case issue #60 exists for.
            // (Unreachable before the wire-shape fix: getBin() threw on every
            // call, so no snapshot was ever written.) Best-effort, like
            // refresh(): a write failure must not turn a successful remove into
            // an error the DJ has to dismiss.
            do {
                try await binStore?.saveSnapshot(entries)
            } catch {
                binLog.error("Bin snapshot save after remove failed: \(error.localizedDescription, privacy: .public). Offline bin may be stale.")
            }
        } catch {
            removeError = (error as? APIError)?.localizedMessage ?? error.localizedDescription
        }
    }
}
