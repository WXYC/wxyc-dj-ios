//
//  InMemoryTokenStorage.swift
//  WXYCAPI
//
//  In-memory TokenStorage for unit tests. Sendable via an internal lock so
//  parallel tests do not clobber each other.
//
//  Created by Jake on 5/14/26.
//  Copyright © 2026 WXYC. All rights reserved.
//

import Foundation
import os

public final class InMemoryTokenStorage: TokenStorage {
    private let state = OSAllocatedUnfairLock<[TokenSlot: String]>(initialState: [:])

    public init() {}

    public func save(_ token: String, for slot: TokenSlot) throws {
        state.withLock { $0[slot] = token }
    }

    public func load(_ slot: TokenSlot) throws -> String? {
        state.withLock { $0[slot] }
    }

    public func clear(_ slot: TokenSlot) throws {
        state.withLock { $0[slot] = nil }
    }

    public func clearAll() throws {
        state.withLock { $0.removeAll() }
    }
}
