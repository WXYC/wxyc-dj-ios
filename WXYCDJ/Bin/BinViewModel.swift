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
    /// The app's error-reporting seam (issue #106). Defaults to
    /// ``NoOpErrorReporter`` so every existing test construction site keeps
    /// compiling unchanged and never fires a real Sentry event; `BinView`
    /// passes `deps.errorReporter` explicitly.
    private let errorReporter: any ErrorReporter
    /// True once `entries` reflects an *authoritative* bin — a persisted snapshot
    /// (even an empty one) or a successful server load — as opposed to "not loaded
    /// yet". This is what consumes the store's never-written-`nil` vs written-
    /// empty-`[]` distinction (issue #60): a present-but-empty bin is authoritative
    /// emptiness ("Bin is empty"), so an offline refresh failure on it shows the
    /// empty tray rather than regressing to "Couldn't load bin".
    private var hasLoadedBin = false

    init(api: APIClient, binStore: (any BinStore)? = nil, errorReporter: any ErrorReporter = NoOpErrorReporter()) {
        self.api = api
        self.binStore = binStore
        self.errorReporter = errorReporter
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
            entries = Self.normalized(try await api.getBin())
            hasLoadedBin = true
            state = .loaded
            // Persist the fresh server truth for the next offline launch.
            await persistSnapshot(after: "refresh")
        } catch let error as APIError {
            errorReporter.report(error, context: "BinViewModel.refresh")
            handleRefreshFailure(error.localizedMessage)
        } catch {
            errorReporter.report(error, context: "BinViewModel.refresh")
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

    /// Write the current `entries` to the offline snapshot. Best-effort: a
    /// failed write must never turn a successful refresh or remove into an
    /// error the DJ has to dismiss — but log it, since a silently stale offline
    /// bin is otherwise invisible to debug. Always fed the normalized list,
    /// which `BinEntry.deduplicatedByAlbum` has already made safe for the
    /// album-id-keyed store.
    private func persistSnapshot(after operation: String) async {
        do {
            try await binStore?.saveSnapshot(entries)
        } catch {
            binLog.error("Bin snapshot save after \(operation, privacy: .public) failed: \(error.localizedDescription, privacy: .public). Offline bin may be stale.")
            errorReporter.report(error, context: "BinViewModel.persistSnapshot")
        }
    }

    /// Shelf order for the bin: the artist's filing name, then album title.
    /// `GET /djs/bin` has no ORDER BY and carries no added-at column, so server
    /// order is arbitrary and unstable across refreshes — sorting here is what
    /// keeps rows from reshuffling under the DJ. It re-runs on every snapshot
    /// load too: `SQLiteBinStore.snapshot()` reads back in album-id (rowid)
    /// order, not the order it was handed.
    ///
    /// The dedupe half is the store's invariant, not a display choice, so it
    /// lives in `WXYCAPI` beside the constraint it protects.
    private static func normalized(_ entries: [BinEntry]) -> [BinEntry] {
        BinEntry.deduplicatedByAlbum(entries).sorted { lhs, rhs in
            let byFilingName = lhs.sortName.localizedStandardCompare(rhs.sortName)
            if byFilingName != .orderedSame { return byFilingName == .orderedAscending }
            return lhs.albumTitle.localizedStandardCompare(rhs.albumTitle) == .orderedAscending
        }
    }

    func remove(_ entry: BinEntry) async {
        do {
            try await api.removeFromBin(albumId: entry.albumId, trackTitle: nil)
            entries.removeAll { $0.albumId == entry.albumId }
            // Mirror the removal into the snapshot, or "remove → relaunch"
            // resurrects the release via loadSnapshot() until a network refresh
            // lands — indefinitely while offline, the case issue #60 exists for.
            await persistSnapshot(after: "remove")
        } catch {
            removeError = (error as? APIError)?.localizedMessage ?? error.localizedDescription
        }
    }
}
