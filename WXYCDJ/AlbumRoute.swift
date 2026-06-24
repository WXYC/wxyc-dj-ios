//
//  AlbumRoute.swift
//  WXYCDJ
//
//  The single value pushed onto every album NavigationStack path and bound
//  to the cold-launch deep-link cover (issue #19 steps 6–7). One hoisted
//  `navigationDestination(for: AlbumRoute.self)` replaces the two
//  state-nested destinations that used to key off AlbumSearchResult (Search)
//  and BinEntry (Bin).
//
//  Equality and hashing key on `id` only — deliberately ignoring `fallback`.
//  A clone-hit route (carrying a looked-up catalog row for an instant header
//  render) and a clone-miss route (`fallback: nil`, resolved by awaiting
//  /library/info) for the same album must coalesce, and AlbumSearchResult's
//  whole-struct Hashable — which differs across a cloned catalog row and a
//  live search row on addDate/artworkURL/plays — must never fragment the
//  navigation path. `fallback` is payload, not identity.
//
//  Created by Jake on 6/23/26.
//  Copyright © 2026 WXYC. All rights reserved.
//

import WXYCAPI

struct AlbumRoute: Hashable, Identifiable {
    /// The album's catalog id — the sole component of identity.
    let id: Int
    /// The looked-up catalog row, when we have one, so AlbumDetailView can
    /// render its header + Catalog section instantly. `nil` on a clone miss;
    /// the detail view then resolves the row by awaiting /library/info.
    var fallback: AlbumSearchResult?

    init(id: Int, fallback: AlbumSearchResult? = nil) {
        self.id = id
        self.fallback = fallback
    }

    static func == (lhs: AlbumRoute, rhs: AlbumRoute) -> Bool {
        lhs.id == rhs.id
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }
}
