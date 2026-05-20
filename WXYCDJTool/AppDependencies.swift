//
//  AppDependencies.swift
//  WXYCDJTool
//
//  Single composition root for the app: picks a WXYCAPIConfiguration
//  (production by default; localhost override via Info.plist), wires the
//  AuthService and APIClient, and is injected through the SwiftUI
//  environment.
//
//  Created by Jake on 5/14/26.
//  Copyright © 2026 WXYC. All rights reserved.
//

import Foundation
import Observation
import WXYCAPI

@MainActor
@Observable
final class AppDependencies {
    let configuration: WXYCAPIConfiguration
    let authService: AuthService
    let api: APIClient

    init() {
        let configuration = Self.resolveConfiguration()
        self.configuration = configuration
        let authService = AuthService(configuration: configuration)
        self.authService = authService
        self.api = APIClient(configuration: configuration, authService: authService)
    }

    private static func resolveConfiguration() -> WXYCAPIConfiguration {
        let bundle = Bundle.main
        if let authString = bundle.object(forInfoDictionaryKey: "WXYCAuthBaseURL") as? String,
           let apiString = bundle.object(forInfoDictionaryKey: "WXYCAPIBaseURL") as? String,
           let authURL = URL(string: authString),
           let apiURL = URL(string: apiString) {
            return WXYCAPIConfiguration(authBaseURL: authURL, apiBaseURL: apiURL)
        }
        return .production
    }
}
