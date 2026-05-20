//
//  Configuration.swift
//  WXYCAPI
//
//  Holds the auth + API base URLs and timeout. Defaults to production
//  (api.wxyc.org), overridable for local development.
//
//  Created by Jake on 5/14/26.
//  Copyright © 2026 WXYC. All rights reserved.
//

import Foundation

public struct WXYCAPIConfiguration: Sendable {
    public let authBaseURL: URL
    public let apiBaseURL: URL
    public let timeout: TimeInterval

    public init(authBaseURL: URL, apiBaseURL: URL, timeout: TimeInterval = 15) {
        self.authBaseURL = authBaseURL
        self.apiBaseURL = apiBaseURL
        self.timeout = timeout
    }

    // The force-unwraps below operate on hard-coded URL literals that are
    // known-good at compile time. A failure here would mean the source
    // string was edited to something invalid, which is a programmer error
    // we want to catch loudly in the very first launch rather than smear
    // across .none-handling at every call site.
    public static let production = WXYCAPIConfiguration(
        authBaseURL: URL(string: "https://api.wxyc.org/auth")!,
        apiBaseURL: URL(string: "https://api.wxyc.org")!
    )

    public static let localDevelopment = WXYCAPIConfiguration(
        authBaseURL: URL(string: "http://localhost:8082/auth")!,
        apiBaseURL: URL(string: "http://localhost:8080")!
    )
}
