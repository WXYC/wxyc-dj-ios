//
//  SpyBinStore.swift
//  WXYCDJTests
//
//  A functional, recording BinStore double for the BinViewModel tests (issue
//  #60). Holds the last saved snapshot so snapshot() behaves like the real
//  store, records every saveSnapshot so the refresh-writes-the-snapshot test can
//  assert what was written, and can be primed with an initial snapshot to model
//  a cold-launch offline read. Can also be told to throw to model an unwritable
//  disk. A lock-guarded Sendable class, matching SpyCatalogStore.
//
//  Created by Jake on 06/28/26.
//  Copyright © 2026 WXYC. All rights reserved.
//

import Foundation
import os
@testable import WXYCAPI

final class SpyBinStore: BinStore {
    struct Failure: Error {}

    private struct State {
        var stored: [BinEntry]?
        var saveCalls: [[BinEntry]] = []
        var throwOnSave: Bool
        var throwOnSnapshot: Bool
    }

    private let state: OSAllocatedUnfairLock<State>

    /// Seed the store with an initial snapshot (`nil` = never written) and the
    /// throw toggles for modelling an unwritable / unreadable disk.
    init(initial: [BinEntry]? = nil, throwOnSave: Bool = false, throwOnSnapshot: Bool = false) {
        state = OSAllocatedUnfairLock(
            initialState: State(stored: initial, throwOnSave: throwOnSave, throwOnSnapshot: throwOnSnapshot)
        )
    }

    /// Every `saveSnapshot` argument, in call order.
    var saveCalls: [[BinEntry]] { state.withLock { $0.saveCalls } }

    // MARK: BinStore

    func snapshot() throws -> [BinEntry]? {
        try state.withLock { st in
            if st.throwOnSnapshot { throw Failure() }
            return st.stored
        }
    }

    func saveSnapshot(_ entries: [BinEntry]) throws {
        try state.withLock { st in
            if st.throwOnSave { throw Failure() }
            st.stored = entries
            st.saveCalls.append(entries)
        }
    }
}
