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
        // `default` case), keyed on the shared AlbumRoute. BinEntry decodes
        // the full /djs/bin projection (issue #80), so a bin row routes a
        // fallback-bearing AlbumRoute via BinEntry.detailFallback — the
        // detail header renders instantly (offline included), and
        // AlbumDetailView still fetches /library/info to replace it with the
        // authoritative row. (issue #19 step 6, issue #87)
        .navigationDestination(for: AlbumRoute.self) { route in
            AlbumDetailView(albumId: route.id, fallback: route.fallback)
        }
        .navigationTitle("My Bin")
        .onAppear {
            if viewModel == nil {
                let vm = BinViewModel(api: deps.api, binStore: deps.binStore, errorReporter: deps.errorReporter)
                viewModel = vm
                // Load the persisted snapshot first (instant offline render),
                // then top up from the network. (issue #60)
                Task {
                    await vm.loadSnapshot()
                    await vm.refresh()
                }
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
                    NavigationLink(value: AlbumRoute(id: entry.albumId, fallback: entry.detailFallback)) {
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
            HStack(spacing: 6) {
                // An unfiled add or a V/A compilation has no call-number legs,
                // so `callNumber` is "" — an empty Text is still a laid-out
                // subview, and the HStack's spacing would indent the capsule
                // 6pt out of line with the title/artist above. Omit it instead.
                if !entry.callNumber.isEmpty {
                    Text(entry.callNumber)
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                }
                if let format = entry.formatName, !format.isEmpty {
                    FormatCapsule(format: format)
                }
            }
        }
        .padding(.vertical, 2)
    }
}
