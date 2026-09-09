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
    @State var showSheet: Bool = false
    @State var showScanner: Bool = false
    @State var scannedCode: String?
    @State var showDeviceAuth: Bool = false

    @State private var toastMessage: String? = nil
    @State private var toastKind: String = "ok"

    var body: some View {
        Group {
            if let viewModel {
                ZStack(alignment: .bottom) {
                    content(for: viewModel)
                        .onChange(of: searchText, initial: false) { _, newValue in
                            viewModel.query = newValue
                        }
                    
                    if let toastMessage {
                        HStack(spacing: 8) {
                            Circle()
                                .fill(toastKind == "red" ? Color.red : toastKind == "amber" ? Color.orange : Color.green)
                                .frame(width: 8, height: 8)
                            
                            Text(toastMessage)
                                .font(.system(size: 13, weight: .medium))
                                .foregroundStyle(.white)
                        }
                        .padding(.horizontal, 14)
                        .padding(.vertical, 10)
                        .background(Color(red: 0.11, green: 0.11, blue: 0.12))
                        .clipShape(Capsule())
                        .shadow(radius: 8)
                        .padding(.bottom, 16)
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                    }
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
                viewModel = SearchViewModel(search: deps.librarySearch, api: deps.api)
            }
        }
        .sheet(isPresented: $showScanner, content: {
            CameraView(showScanner: $showScanner, scannedCode: $scannedCode, onDismiss: {
                showScanner = false
                if scannedCode != nil {
                    showDeviceAuth = true
                }
            })
        })
        .sheet(isPresented: $showDeviceAuth, content: {
            DeviceAuthView(
                scannedCode: $scannedCode,
                onDismissWithToast: { text, kind in
                    showToast(text, kind: kind)
                }
            )
            .presentationDetents([.fraction(0.68)])
            .presentationDragIndicator(.visible)
        })
        .onChange(of: showDeviceAuth) { _, isPresented in
            if !isPresented {
                scannedCode = nil
            }
        }
    }
    
    private func showToast(_ text: String, kind: String = "ok") {
        withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) {
            toastMessage = text
            toastKind = kind
        }
        Task {
            try? await Task.sleep(for: .seconds(2.5))
            withAnimation(.easeOut(duration: 0.25)) {
                toastMessage = nil
            }
        }
    }
    
    @ToolbarContentBuilder
    private var signOutMenu: some ToolbarContent {
        ToolbarItem(placement: .topBarTrailing) {
            Menu {
                if case .signedIn(let payload) = auth.state {
                    let handle = payload?.email?.components(separatedBy: "@").first ?? payload?.sub ?? "biscuit"
                    Section {
                        Text("Signed in as \(handle) [\(payload?.role?.uppercased() ?? "DJ")]")
                            .font(.caption)
                    }
                }
                
                Button {
                } label: {
                    Label("Profile", systemImage: "person")
                }
                
                Button {
                    showScanner = true
                } label: {
                    Label("Scan QR to sign in browser", systemImage: "qrcode.viewfinder")
                }
                
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
            if viewModel.source == .local {
                // The offline FTS clone (or a failed live request falling back to
                // it) found nothing. Frame it as the saved library so a miss here
                // doesn't read as a confirmed "not in the WXYC library" — the live
                // catalog wasn't consulted (issue #58).
                ContentUnavailableView {
                    Label("No saved matches", systemImage: "wifi.slash")
                } description: {
                    Text("Nothing in the saved library matches \u{201C}\(viewModel.query)\u{201D}.")
                }
            } else {
                ContentUnavailableView.search(text: viewModel.query)
            }
        case .results:
            List {
                // When the offline FTS clone served these results, lead with a
                // quiet note so the DJ knows they're looking at the saved library
                // (bm25 ranking, artist/album/call-number only — no track hints).
                if viewModel.source == .local {
                    Section {
                        Label("Showing saved library", systemImage: "wifi.slash")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }
                Section {
                    ForEach(viewModel.results) { row in
                        // Carry the live row as the route's fallback so the detail
                        // header renders instantly while /library/info + LML load.
                        NavigationLink(value: AlbumRoute(id: row.id, fallback: row)) {
                            SearchResultRow(row: row) {
                                Task { _ = await viewModel.addToBin(row) }
                            }
                        }
                    }
                }
            }
            .listStyle(.plain)
        }
    }
}
