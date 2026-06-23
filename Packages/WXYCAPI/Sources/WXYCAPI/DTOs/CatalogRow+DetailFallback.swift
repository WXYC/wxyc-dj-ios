//
//  CatalogRow+DetailFallback.swift
//  WXYCAPI
//
//  Bridges a cloned CatalogRow to an AlbumSearchResult so a Spotlight deep link
//  can render AlbumDetailView's header instantly from the local store, before
//  the live /library/info fetch resolves (issue #19 step 2).
//
//  Created by Jake on 06/22/26.
//  Copyright © 2026 WXYC. All rights reserved.
//

import Foundation

public extension CatalogRow {
    /// An `AlbumSearchResult` stand-in built from this cloned row, for the
    /// instant header render of `AlbumDetailView` (which takes an
    /// `AlbumSearchResult?` `fallback`). The shared catalog fields map straight
    /// across; `rotationBin` is projected through ``rotationCohort`` so only a
    /// display cohort (`H`/`M`/`L`/`S`) survives — a raw `"N"` becomes `nil`,
    /// which is fine because the detail view re-fetches authoritative rotation
    /// from `/library/info`. Fields the export projection never carries, or that
    /// exist only to decorate search results (`addDate`, `labelId`, `rotationId`,
    /// `albumArtist`, `matchedVia`), are `nil`/`[]`.
    ///
    /// This is lossless **for the header render**, not a full round-trip: the
    /// detail view's authoritative shelf data still comes from `/library/info`.
    var detailFallback: AlbumSearchResult {
        AlbumSearchResult(
            id: id,
            addDate: nil,
            albumTitle: albumTitle,
            artistName: artistName,
            codeLetters: codeLetters,
            codeNumber: codeNumber,
            codeArtistNumber: codeArtistNumber,
            formatName: formatName,
            genreName: genreName,
            label: label,
            labelId: nil,
            rotationBin: rotationCohort,
            rotationId: nil,
            plays: plays,
            onStreaming: onStreaming,
            albumArtist: nil,
            artworkURL: artworkURL,
            matchedVia: []
        )
    }
}
