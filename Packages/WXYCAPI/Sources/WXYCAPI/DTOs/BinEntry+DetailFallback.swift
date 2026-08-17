//
//  BinEntry+DetailFallback.swift
//  WXYCAPI
//
//  Bridges a bin row to an AlbumSearchResult so AlbumDetailView can render
//  its header instantly from data already on screen — mirrors
//  CatalogRow+DetailFallback.swift (issue #19 step 2) for the Bin -> Detail
//  path (issue #87).
//
//  Created by Jake on 08/16/26.
//  Copyright © 2026 WXYC. All rights reserved.
//

import Foundation

public extension BinEntry {
    /// An `AlbumSearchResult` stand-in built from this bin row, for the
    /// instant header render of `AlbumDetailView` (which takes an
    /// `AlbumSearchResult?` `fallback`). The `/djs/bin` projection (issue
    /// #80) carries title, artist, label, and all three call-number legs
    /// plus format/genre — everything the header needs except artwork and
    /// play count.
    ///
    /// `artworkURL` and `plays` are deliberately `nil`: the bin projection
    /// doesn't carry either (see the type's header note), and widening
    /// `BinEntry` to fetch them here would duplicate what `AlbumDetailView`
    /// already does against `/library/info` and the on-device catalog clone.
    /// `rotationBin` is `nil` for the same reason as
    /// `CatalogRow.detailFallback` — the projection carries no rotation data
    /// at all, so there's nothing to bridge. Fields the projection never
    /// carries, or that exist only to decorate search results (`addDate`,
    /// `labelId`, `rotationId`, `onStreaming`, `albumArtist`, `matchedVia`),
    /// are likewise `nil`/`[]`.
    ///
    /// Lossless **for the header render**, not a full round-trip: the detail
    /// view's authoritative shelf data, artwork, and LML enrichment still
    /// come from `/library/info` and `/proxy/metadata/album`.
    var detailFallback: AlbumSearchResult {
        AlbumSearchResult(
            id: albumId,
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
            plays: nil,
            onStreaming: nil,
            albumArtist: nil,
            artworkURL: nil,
            matchedVia: []
        )
    }
}
