//
//  RootView.swift
//  WXYCDJ
//
//  Auth gate. Observes AuthService.state and shows LoginView or MainView.
//
//  Created by Jake on 5/14/26.
//  Copyright © 2026 WXYC. All rights reserved.
//

import SwiftUI
import WXYCAPI

struct RootView: View {
    @Environment(AuthService.self) private var auth

    var body: some View {
        switch auth.state {
        case .unknown, .signingIn:
            ProgressView()
                .progressViewStyle(.circular)
        case .signedOut:
            LoginView()
        case .signedIn:
            MainView()
        }
    }
}
