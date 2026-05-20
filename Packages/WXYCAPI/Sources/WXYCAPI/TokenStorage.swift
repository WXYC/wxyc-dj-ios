//
//  TokenStorage.swift
//  WXYCAPI
//
//  Persistent home for the better-auth session token. Keychain-backed in
//  production; an in-memory implementation lives in InMemoryTokenStorage for
//  unit tests. Two slots so the JWT (short-lived, cacheable) can be evicted
//  independently of the session token (long-lived, the source of truth).
//
//  Created by Jake on 5/14/26.
//  Copyright © 2026 WXYC. All rights reserved.
//

import Foundation

public enum TokenSlot: String, Sendable {
    case sessionToken = "wxyc.dj-tool.session-token"
    case jwt = "wxyc.dj-tool.jwt"
}

public protocol TokenStorage: Sendable {
    func save(_ token: String, for slot: TokenSlot) throws
    func load(_ slot: TokenSlot) throws -> String?
    func clear(_ slot: TokenSlot) throws
    func clearAll() throws
}

public enum TokenStorageError: Error, Sendable, Equatable {
    case underlying(OSStatus)
    case encodingFailed
}
