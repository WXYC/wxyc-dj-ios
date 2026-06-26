//
//  KeychainTokenStorage.swift
//  WXYCAPI
//
//  Keychain-backed TokenStorage. Generic password items, accessible only when
//  the device is unlocked, scoped to the app via kSecAttrService.
//
//  Created by Jake on 5/14/26.
//  Copyright © 2026 WXYC. All rights reserved.
//

import Foundation
import Security

public struct KeychainTokenStorage: TokenStorage {
    private let service: String

    public init(service: String = "org.wxyc.dj") {
        self.service = service
    }

    public func save(_ token: String, for slot: TokenSlot) throws {
        guard let data = token.data(using: .utf8) else {
            throw TokenStorageError.encodingFailed
        }
        let baseQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: slot.rawValue,
        ]
        let attributes: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
        ]
        // Canonical Keychain upsert: try SecItemUpdate first, fall back to
        // SecItemAdd on errSecItemNotFound. The two-step pattern has a
        // theoretical TOCTOU window (the item could be deleted between the
        // update and the add), but AuthService is @MainActor-isolated so
        // concurrent saves can't interleave with deletes from the same app.
        let updateStatus = SecItemUpdate(baseQuery as CFDictionary, attributes as CFDictionary)
        switch updateStatus {
        case errSecSuccess:
            return
        case errSecItemNotFound:
            var addQuery = baseQuery
            addQuery.merge(attributes) { _, new in new }
            let addStatus = SecItemAdd(addQuery as CFDictionary, nil)
            guard addStatus == errSecSuccess else {
                throw TokenStorageError.underlying(addStatus)
            }
        default:
            throw TokenStorageError.underlying(updateStatus)
        }
    }

    public func load(_ slot: TokenSlot) throws -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: slot.rawValue,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        switch status {
        case errSecSuccess:
            guard let data = item as? Data, let token = String(data: data, encoding: .utf8) else {
                return nil
            }
            return token
        case errSecItemNotFound:
            return nil
        default:
            throw TokenStorageError.underlying(status)
        }
    }

    public func clear(_ slot: TokenSlot) throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: slot.rawValue,
        ]
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw TokenStorageError.underlying(status)
        }
    }

    public func clearAll() throws {
        try clear(.sessionToken)
        try clear(.jwt)
        // Issue #57: the grace-window anchors are terminal-cleared too, so a
        // 401/manual sign-out leaves nothing for the offline restore to revive.
        try clear(.lastValidatedAt)
        try clear(.payload)
    }
}
