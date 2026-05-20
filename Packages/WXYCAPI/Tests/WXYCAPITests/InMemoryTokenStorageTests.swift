//
//  InMemoryTokenStorageTests.swift
//  WXYCAPITests
//
//  Created by Jake on 5/14/26.
//  Copyright © 2026 WXYC. All rights reserved.
//

import Testing
@testable import WXYCAPI

@Suite("InMemoryTokenStorage")
struct InMemoryTokenStorageTests {
    @Test func saveAndLoadRoundTrip() throws {
        let storage = InMemoryTokenStorage()
        try storage.save("abc", for: .sessionToken)
        #expect(try storage.load(.sessionToken) == "abc")
    }

    @Test func slotsAreIndependent() throws {
        let storage = InMemoryTokenStorage()
        try storage.save("session", for: .sessionToken)
        try storage.save("jwt", for: .jwt)
        #expect(try storage.load(.sessionToken) == "session")
        #expect(try storage.load(.jwt) == "jwt")
    }

    @Test func clearSlotLeavesOthers() throws {
        let storage = InMemoryTokenStorage()
        try storage.save("s", for: .sessionToken)
        try storage.save("j", for: .jwt)
        try storage.clear(.sessionToken)
        #expect(try storage.load(.sessionToken) == nil)
        #expect(try storage.load(.jwt) == "j")
    }

    @Test func clearAllEmpties() throws {
        let storage = InMemoryTokenStorage()
        try storage.save("s", for: .sessionToken)
        try storage.save("j", for: .jwt)
        try storage.clearAll()
        #expect(try storage.load(.sessionToken) == nil)
        #expect(try storage.load(.jwt) == nil)
    }
}
