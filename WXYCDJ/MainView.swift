//
//  MainView.swift
//  WXYCDJ
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

    @State var showSheet: Bool = false
    @State var qrCode: String = ""
    @State var showScanner: Bool = false
    var title: String = "Signed in as ..."
    
    var body: some View {
        TabView {
            Tab("Search", systemImage: "magnifyingglass") {
                NavigationStack { SearchView() }
            }
            Tab("Bin", systemImage: "tray") {
                NavigationStack { BinView() }
            }
        }
        .toolbar {
                    ToolbarItem {
                        Button { showSheet.toggle()
                        } label: {
                            Label("Choose Category", systemImage: "line.3.horizontal.decrease.circle")
                        }
                    }
                }
                .confirmationDialog(
                            title,
                            isPresented: $showSheet
                        ) {
                            Button {
                             } label: {
                                 Label("Profile", systemImage: "line.3.horizontal.decrease.circle")
                             }
                           Button { showSheet = true
                            } label: {
                                Label("QR Code Scanner", systemImage: "line.3.horizontal.decrease.circle")
                            }
                            
                            Button("Sign Out", role: .destructive) {
                                showSheet = false
                            }
                            Button("Cancel", role: .cancel) {
                                showSheet = false
                            }
                        } .sheet(isPresented: $showScanner, content: {CameraView(showScanner: $showScanner, qrCode: $qrCode, onDismiss: {showScanner = false})})
    }
}
