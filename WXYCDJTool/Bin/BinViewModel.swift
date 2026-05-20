//
//  BinViewModel.swift
//  WXYCDJTool
//
//  Owns the local cache of GET /djs/bin and exposes refresh + remove.
//
//  Created by Jake on 5/14/26.
//  Copyright © 2026 WXYC. All rights reserved.
//

import Foundation
import Observation
import WXYCAPI

@MainActor
@Observable
final class BinViewModel {
    enum State: Sendable, Equatable {
        case loading
        case loaded
        case error(String)
    }

    private(set) var entries: [BinEntry] = []
    private(set) var state: State = .loading

    private let api: APIClient

    init(api: APIClient) {
        self.api = api
    }

    func refresh() async {
        state = .loading
        do {
            let response = try await api.getBin()
            entries = response.entries.sorted { $0.addedAt > $1.addedAt }
            state = .loaded
        } catch let error as APIError {
            state = .error(error.localizedMessage)
        } catch {
            state = .error(error.localizedDescription)
        }
    }

    func remove(_ entry: BinEntry) async {
        do {
            try await api.removeFromBin(albumId: entry.albumId, trackTitle: nil)
            entries.removeAll { $0.id == entry.id }
        } catch {
            state = .error((error as? APIError)?.localizedMessage ?? error.localizedDescription)
        }
    }
}
