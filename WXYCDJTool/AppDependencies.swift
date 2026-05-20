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
import OSLog
import WXYCAPI

private let configLog = Logger(subsystem: "org.wxyc.dj-tool", category: "config")

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
        let authString = bundle.object(forInfoDictionaryKey: "WXYCAuthBaseURL") as? String
        let apiString = bundle.object(forInfoDictionaryKey: "WXYCAPIBaseURL") as? String

        // Neither key set — production is the intended default.
        if authString == nil && apiString == nil {
            return .production
        }

        // At least one key was provided; a misconfiguration here used to
        // silently fall back to production and hit the real backend during
        // local dev. Log loudly instead.
        guard let authString, let apiString else {
            configLog.warning(
                "Partial WXYCAPIConfiguration override: WXYCAuthBaseURL=\(authString ?? "<missing>", privacy: .public), WXYCAPIBaseURL=\(apiString ?? "<missing>", privacy: .public). Both keys must be set to override .production; falling back."
            )
            return .production
        }
        guard let authURL = URL(string: authString), let apiURL = URL(string: apiString) else {
            configLog.warning(
                "WXYCAPIConfiguration override has unparseable URL(s): WXYCAuthBaseURL=\(authString, privacy: .public), WXYCAPIBaseURL=\(apiString, privacy: .public). Falling back to .production."
            )
            return .production
        }
        return WXYCAPIConfiguration(authBaseURL: authURL, apiBaseURL: apiURL)
    }
}
