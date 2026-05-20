//
//  WXYCDJToolApp.swift
//  WXYCDJTool
//
//  App entry point. Constructs AppDependencies (AuthService + APIClient)
//  once at launch and hands them to RootView via the environment.
//
//  Created by Jake on 5/14/26.
//  Copyright © 2026 WXYC. All rights reserved.
//

import SwiftUI
import WXYCAPI

@main
struct WXYCDJToolApp: App {
    @State private var dependencies = AppDependencies()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(dependencies)
                .environment(dependencies.authService)
                .task {
                    await dependencies.authService.restoreSession()
                }
        }
    }
}
