//
//  BinStore.swift
//  WXYCAPI
//
//  Protocol for the on-device persistence of the DJ's bin (issue #60): hold the
//  last server snapshot so the bin reads offline. Kept on its own store/actor,
//  independent of the catalog clone, so a bin read never waits behind a
//  multi-second catalog replace. A protocol so the BinViewModel can be tested
//  against a spy.
//
//  Created by Jake on 06/28/26.
//  Copyright © 2026 WXYC. All rights reserved.
//

import Foundation

/// Persists the last successful server bin snapshot (`GET /djs/bin`) so the bin
/// renders offline. The read-only foundation for the offline-bin-write work in
/// #61/#62, which will extend this with a pending-intention map — adding
/// `pending()`/`savePending()` here later won't break #60's two methods.
///
/// `Sendable` because the ``BinViewModel`` is `@MainActor` but the store is an
/// `actor` reached across the isolation boundary.
public protocol BinStore: Sendable {
    /// The last persisted server snapshot, or `nil` if one was never written.
    /// A written-but-empty bin returns `[]`, distinct from the never-written
    /// `nil` — the caller uses that to avoid treating "no snapshot yet" as "the
    /// bin is empty".
    func snapshot() async throws -> [BinEntry]?

    /// Replace the persisted snapshot wholesale with `entries` (including the
    /// empty case, which records a present-but-empty snapshot).
    func saveSnapshot(_ entries: [BinEntry]) async throws
}
