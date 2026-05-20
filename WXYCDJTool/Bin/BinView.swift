//
//  BinView.swift
//  WXYCDJTool
//
//  Shows the DJ's bin. Pull-to-refresh hits GET /djs/bin; swipe-to-remove
//  hits DELETE /djs/bin. Tapping a row pushes the album detail.
//
//  Created by Jake on 5/14/26.
//  Copyright © 2026 WXYC. All rights reserved.
//

import SwiftUI
import WXYCAPI

struct BinView: View {
    @Environment(AppDependencies.self) private var deps
    @State private var viewModel: BinViewModel?

    var body: some View {
        Group {
            if let viewModel {
                content(for: viewModel)
            } else {
                ProgressView()
            }
        }
        .navigationTitle("My Bin")
        .onAppear {
            if viewModel == nil {
                viewModel = BinViewModel(api: deps.api)
                Task { await viewModel?.refresh() }
            }
        }
    }

    @ViewBuilder
    private func content(for viewModel: BinViewModel) -> some View {
        switch viewModel.state {
        case .loading where viewModel.entries.isEmpty:
            ProgressView()
        case .error(let message) where viewModel.entries.isEmpty:
            ContentUnavailableView("Couldn't load bin",
                                   systemImage: "exclamationmark.triangle",
                                   description: Text(message))
        case .loaded where viewModel.entries.isEmpty:
            ContentUnavailableView("Bin is empty",
                                   systemImage: "tray",
                                   description: Text("Add releases from the Search tab."))
        default:
            List {
                ForEach(viewModel.entries) { entry in
                    NavigationLink(value: entry) {
                        BinRow(entry: entry)
                    }
                    .swipeActions {
                        Button("Remove", role: .destructive) {
                            Task { await viewModel.remove(entry) }
                        }
                    }
                }
            }
            .listStyle(.plain)
            .refreshable { await viewModel.refresh() }
            .navigationDestination(for: BinEntry.self) { entry in
                AlbumDetailView(albumId: entry.albumId, fallback: nil)
            }
        }
    }
}

struct BinRow: View {
    let entry: BinEntry

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(entry.albumTitle).bold().lineLimit(1)
            Text(entry.artistName).foregroundStyle(.secondary).lineLimit(1)
            Text(entry.callNumber)
                .font(.caption.monospaced())
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 2)
    }
}
