//
//  AppDependenciesTests.swift
//  WXYCDJTests
//
//  Pins AppDependencies.resolveConfiguration's five branches: both keys
//  unset returns .production; either key missing returns .production
//  (the partial-config guard); unparseable URLs return .production; and
//  two valid URLs return a custom configuration. Documents the Info.plist
//  override contract so a future refactor can't silently send local-dev
//  traffic to api.wxyc.org.
//
//  Created by Jake on 5/20/26.
//  Copyright © 2026 WXYC. All rights reserved.
//

import Foundation
import Testing
import WXYCAPI
@testable import WXYCDJ

@Suite("AppDependencies.resolveConfiguration")
@MainActor
struct AppDependenciesTests {
    @Test func bothNilReturnsProduction() {
        let config = AppDependencies.resolveConfiguration(authString: nil, apiString: nil)

        #expect(config.authBaseURL == WXYCAPIConfiguration.production.authBaseURL)
        #expect(config.apiBaseURL == WXYCAPIConfiguration.production.apiBaseURL)
    }

    @Test func authStringMissingReturnsProduction() {
        let config = AppDependencies.resolveConfiguration(
            authString: nil,
            apiString: "http://localhost:8080"
        )

        #expect(config.authBaseURL == WXYCAPIConfiguration.production.authBaseURL)
        #expect(config.apiBaseURL == WXYCAPIConfiguration.production.apiBaseURL)
    }

    @Test func apiStringMissingReturnsProduction() {
        let config = AppDependencies.resolveConfiguration(
            authString: "http://localhost:8082/auth",
            apiString: nil
        )

        #expect(config.authBaseURL == WXYCAPIConfiguration.production.authBaseURL)
        #expect(config.apiBaseURL == WXYCAPIConfiguration.production.apiBaseURL)
    }

    @Test func unparseableURLReturnsProduction() {
        // Unterminated IPv6 bracket — fails URL(string:) reliably across
        // Foundation's permissive and strict parsers. Empty strings or
        // generic gibberish don't, since iOS 17+ URL is lenient about
        // both.
        let config = AppDependencies.resolveConfiguration(
            authString: "http://[::1",
            apiString: "http://[::1"
        )

        #expect(config.authBaseURL == WXYCAPIConfiguration.production.authBaseURL)
        #expect(config.apiBaseURL == WXYCAPIConfiguration.production.apiBaseURL)
    }

    @Test func bothValidReturnsCustomConfiguration() throws {
        let config = AppDependencies.resolveConfiguration(
            authString: "http://localhost:8082/auth",
            apiString: "http://localhost:8080"
        )

        #expect(config.authBaseURL.absoluteString == "http://localhost:8082/auth")
        #expect(config.apiBaseURL.absoluteString == "http://localhost:8080")
    }
}
