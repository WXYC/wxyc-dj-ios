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
    /// across — the header reads title, artist, artwork, and label, with the
    /// call-number legs and other lossless fields carried along for a richer
    /// instant render.
    ///
    /// `rotationBin` is deliberately **not** bridged (left `nil`):
    /// `AlbumSearchResult.rotationBin` is a `H`/`M`/`L`/`S` cohort enum and
    /// cannot faithfully represent a raw catalog bin — it would collapse a valid
    /// `"N"` (still in rotation per the server predicate) to `nil` and read as
    /// out of rotation. Rotation state for a cloned row comes from
    /// ``isInRotation(asOf:timeZone:)`` / ``rotationCohort`` on the `CatalogRow`
    /// itself, not from this bridge. Fields the export projection never carries,
    /// or that exist only to decorate search results (`addDate`, `labelId`,
    /// `rotationId`, `albumArtist`, `matchedVia`), are likewise `nil`/`[]`.
    ///
    /// Lossless **for the header render**, not a full round-trip: the detail
    /// view's authoritative shelf + rotation data still come from `/library/info`.
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
            rotationBin: nil,
            rotationId: nil,
            plays: plays,
            onStreaming: onStreaming,
            albumArtist: nil,
            artworkURL: artworkURL,
            matchedVia: []
        )
    }
}
