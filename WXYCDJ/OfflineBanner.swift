//
//  OfflineBanner.swift
//  WXYCDJ
//
//  A thin top bar (issue #56) shown only while ConnectivityMonitor reports the
//  app offline, so a DJ always knows they're working from saved data and how
//  fresh it is. Reads the monitor + the catalog "last synced" line from the
//  environment; renders nothing when online, so the RootView safeAreaInset that
//  hosts it reserves no space until needed.
//
//  Created by Jake on 6/26/26.
//  Copyright © 2026 WXYC. All rights reserved.
//

import SwiftUI
import WXYCAPI

struct OfflineBanner: View {
    @Environment(ConnectivityMonitor.self) private var connectivity
    @Environment(AppDependencies.self) private var deps

    var body: some View {
        if !connectivity.isOnline {
            bar
        }
    }

    private var bar: some View {
        HStack(spacing: 8) {
            Image(systemName: "wifi.slash")
                .font(.subheadline.weight(.semibold))
            VStack(alignment: .leading, spacing: 1) {
                Text("Offline")
                    .font(.subheadline.weight(.semibold))
                Text(syncText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.regularMaterial)
        .overlay(alignment: .bottom) {
            Divider()
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Offline. \(syncText)")
    }

    /// The freshness line: the formatted catalog watermark, or a placeholder
    /// before the first successful sync.
    private var syncText: String {
        if let synced = deps.lastCatalogSyncText {
            "Last synced \(synced)"
        } else {
            "Never synced"
        }
    }
}
