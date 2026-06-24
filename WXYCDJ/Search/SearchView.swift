//
//  SearchView.swift
//  WXYCDJ
//
//  The signed-in DJ's primary screen: a List bound to a SearchViewModel,
//  driven by a .searchable text field. Tap a row to push the detail view;
//  + adds it to the bin.
//
//  Created by Jake on 5/14/26.
//  Copyright © 2026 WXYC. All rights reserved.
//

import SwiftUI
import WXYCAPI

struct SearchView: View {
    @Environment(AppDependencies.self) private var deps
    @Environment(AuthService.self) private var auth
    @State private var viewModel: SearchViewModel?
    @State private var searchText: String = ""

    var body: some View {
        Group {
            if let viewModel {
                content(for: viewModel)
                    .onChange(of: searchText, initial: false) { _, newValue in
                        viewModel.query = newValue
                    }
            } else {
                ProgressView()
            }
        }
        // One destination, hoisted onto the always-mounted Group so it's
        // registered in every view state (idle/searching/empty/error/results),
        // not just .results. A state-nested destination is unreachable for a
        // programmatic push and trips the "no matching navigationDestination"
        // warning; keying on AlbumRoute also lets the in-app tap and the
        // deep-link push (step 7) share one destination. (issue #19 step 6)
        .navigationDestination(for: AlbumRoute.self) { route in
            AlbumDetailView(albumId: route.id, fallback: route.fallback)
        }
        .navigationTitle("Library")
        .searchable(text: $searchText, prompt: "Artist or album")
        .toolbar { signOutMenu }
        .onAppear {
            if viewModel == nil {
                viewModel = SearchViewModel(api: deps.api)
            }
        }
    }

    @ToolbarContentBuilder
    private var signOutMenu: some ToolbarContent {
        ToolbarItem(placement: .topBarTrailing) {
            Menu {
                Button("Sign Out", role: .destructive) {
                    Task { await auth.signOut() }
                }
            } label: {
                Image(systemName: "person.crop.circle")
            }
        }
    }

    @ViewBuilder
    private func content(for viewModel: SearchViewModel) -> some View {
        switch viewModel.state {
        case .idle:
            ContentUnavailableView("Search the library", systemImage: "magnifyingglass",
                                   description: Text("Type at least two characters."))
        case .searching:
            List {
                HStack {
                    ProgressView()
                    Text("Searching…").foregroundStyle(.secondary)
                }
            }
        case .empty:
            ContentUnavailableView.search(text: viewModel.query)
        case .error(let message):
            ContentUnavailableView("Couldn't search", systemImage: "exclamationmark.triangle",
                                   description: Text(message))
        case .results:
            List(viewModel.results) { row in
                // Carry the live row as the route's fallback so the detail
                // header renders instantly while /library/info + LML load.
                NavigationLink(value: AlbumRoute(id: row.id, fallback: row)) {
                    SearchResultRow(row: row) {
                        Task { _ = await viewModel.addToBin(row) }
                    }
                }
            }
            .listStyle(.plain)
        }
    }
}
