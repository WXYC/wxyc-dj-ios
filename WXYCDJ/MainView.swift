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
    @State var scannedCode: String?
    @State var showScanner: Bool = false
    @State var showDeviceAuth: Bool = false
    @State var codeFound: Bool = false
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
        .toolbar { signOutMenu }
        /*
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
                            
                           
                            
                            Button("Sign In", role: .destructive) {
                                showSheet = false
                            }
                            Button("Cancel", role: .cancel) {
                                showSheet = false
                            }
         } */ .sheet(isPresented: $showScanner, content: {CameraView(showScanner: $showScanner, scannedCode: $scannedCode, onDismiss: {
             showScanner = false
             showDeviceAuth = true
         })})
         .sheet(isPresented: $showDeviceAuth, content: {DeviceAuthView(scannedCode: $scannedCode)})
            }
    
    @ToolbarContentBuilder
    private var signOutMenu: some ToolbarContent {
        ToolbarItem(placement: .topBarTrailing) {
            Menu {
                Button {
                 } label: {
                     Label("Profile", systemImage: "person")
                 }
                Button { showSheet = true
                 } label: {
                     Label("QR Code Scanner", systemImage: /*insert qr symbol thing*/)
                 }
                Button("Sign Out", role: .destructive) { /*insert symbol thing*/
                    Task { await auth.signOut() }
                }
                
                
            } label: {
                Image(systemName: "person.crop.circle")
            }
        }
    }

}
