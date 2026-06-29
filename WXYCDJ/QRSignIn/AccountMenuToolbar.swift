//
//  AccountMenuToolbar.swift
//  WXYCDJ
//
//  Shared `ToolbarContent` for the Search and Bin tabs: an account menu in the
//  top-trailing corner showing Sign Out (always) and Scan QR (when the
//  WXYCQRSignInEnabled feature gate is on). Replaces the per-view `signOutMenu`
//  the two tabs used to duplicate.
//
//  Created by Jake on 6/28/26.
//  Copyright © 2026 WXYC. All rights reserved.
//

import SwiftUI

struct AccountMenuToolbar: ToolbarContent {
    let onScanQR: () -> Void
    let onSignOut: () -> Void
    /// Read once from `AppDependencies` per host. Set in `project.yml` as
    /// `WXYCQRSignInEnabled: false` for the v1 build; flip on once the
    /// Backend-Service `/auth/device/verify` endpoint is live.
    let qrSignInEnabled: Bool

    var body: some ToolbarContent {
        ToolbarItem(placement: .topBarTrailing) {
            Menu {
                if qrSignInEnabled {
                    Button {
                        onScanQR()
                    } label: {
                        Label("Scan QR to sign in browser", systemImage: "qrcode.viewfinder")
                    }
                    Divider()
                }
                Button("Sign Out", role: .destructive, action: onSignOut)
            } label: {
                Image(systemName: "person.crop.circle")
            }
        }
    }
}
