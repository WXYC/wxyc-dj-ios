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
    /// `artworkURL`, `plays`, and `onStreaming` are left at the factory's `nil`
    /// default: the bin projection carries none of them (see the type's header
    /// note), and widening `BinEntry` to fetch them here would duplicate what
    /// `AlbumDetailView` already does against `/library/info` and the on-device
    /// catalog clone. An artwork-less fallback is *expected* downstream —
    /// `AlbumDetailView.shouldReadCloneForArtwork` branches on
    /// `fallback?.artworkURL`, not on whether `fallback` itself is nil, so the
    /// clone stays the artwork backstop on this path exactly as it was when Bin
    /// rows routed `fallback: nil`.
    ///
    /// What a stand-in deliberately drops — including why `rotationBin` is
    /// never bridged — is decided once in
    /// ``AlbumSearchResult/headerStandIn(id:albumTitle:artistName:codeLetters:codeNumber:codeArtistNumber:formatName:genreName:label:plays:onStreaming:artworkURL:)``.
    var detailFallback: AlbumSearchResult {
        .headerStandIn(
            id: albumId,
            albumTitle: albumTitle,
            artistName: artistName,
            codeLetters: codeLetters,
            codeNumber: codeNumber,
            codeArtistNumber: codeArtistNumber,
            formatName: formatName,
            genreName: genreName,
            label: label
        )
    }
}
