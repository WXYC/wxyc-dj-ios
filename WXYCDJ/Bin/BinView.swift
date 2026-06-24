//
//  BinView.swift
//  WXYCDJ
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
        // Hoisted onto the always-mounted Group (was nested in the non-empty
        // `default` case), keyed on the shared AlbumRoute. A bin row carries no
        // catalog clone, so fallback is nil — AlbumDetailView resolves the row
        // by awaiting /library/info. (issue #19 step 6)
        .navigationDestination(for: AlbumRoute.self) { route in
            AlbumDetailView(albumId: route.id, fallback: route.fallback)
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
                    NavigationLink(value: AlbumRoute(id: entry.albumId, fallback: nil)) {
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
            // The list itself stays mounted on a remove failure (state stays
            // .loaded), so the error has to surface in a non-destructive way.
            // Tap-to-dismiss alert is enough; the row is still there to retry.
            .alert(
                "Couldn't remove",
                isPresented: Binding(
                    get: { viewModel.removeError != nil },
                    set: { if !$0 { viewModel.removeError = nil } }
                ),
                presenting: viewModel.removeError
            ) { _ in
                Button("OK", role: .cancel) {}
            } message: { message in
                Text(message)
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
