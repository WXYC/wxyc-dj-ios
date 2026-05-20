//
//  MainView.swift
//  WXYCDJTool
//
//  Two-tab shell for the signed-in DJ: Search and Bin. Sign-out lives in
//  the navigation toolbar of each tab.
//
//  Created by Jake on 5/14/26.
//  Copyright © 2026 WXYC. All rights reserved.
//

import SwiftUI
import WXYCAPI

struct MainView: View {
    @Environment(AuthService.self) private var auth

    var body: some View {
        TabView {
            Tab("Search", systemImage: "magnifyingglass") {
                NavigationStack { SearchView() }
            }
            Tab("Bin", systemImage: "tray") {
                NavigationStack { BinView() }
            }
        }
    }
}
