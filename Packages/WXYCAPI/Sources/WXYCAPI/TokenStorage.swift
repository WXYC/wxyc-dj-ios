//
//  TokenStorage.swift
//  WXYCAPI
//
//  Persistent home for the better-auth session token. Keychain-backed in
//  production; an in-memory implementation lives in InMemoryTokenStorage for
//  unit tests. Two slots so the JWT (short-lived, cacheable) can be evicted
//  independently of the session token (long-lived, the source of truth); two
//  more (issue #57) anchor the offline grace window — the last confirmed
//  server contact and a durable copy of the last token payload — so a cold
//  launch offline can stay signed in on the cached identity.
//
//  Created by Jake on 5/14/26.
//  Copyright © 2026 WXYC. All rights reserved.
//

import Foundation

public enum TokenSlot: String, Sendable {
    case sessionToken = "wxyc.dj-tool.session-token"
    case jwt = "wxyc.dj-tool.jwt"
    /// Wall-clock of the last confirmed server contact (a successful JWT
    /// exchange/rotation), stored as `String(date.timeIntervalSince1970)`.
    /// Anchors the offline grace window (issue #57).
    case lastValidatedAt = "wxyc.dj-tool.last-validated-at"
    /// Durable JSON of the last `JWTPayload`, so an offline cold launch can
    /// reconstruct the signed-in identity without a network round-trip. Lives
    /// in its own slot so a transient `invalidateJWT()` (which clears `.jwt`)
    /// never erases it (issue #57).
    case payload = "wxyc.dj-tool.payload"
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
