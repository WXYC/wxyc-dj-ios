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
    /// The export projection carries artwork, plays, and the streaming flag, so
    /// all three are bridged. What a stand-in deliberately drops — including
    /// why `rotationBin` is never bridged — is decided once in
    /// ``AlbumSearchResult/headerStandIn(id:albumTitle:artistName:codeLetters:codeNumber:codeArtistNumber:formatName:genreName:label:plays:onStreaming:artworkURL:)``;
    /// rotation state for a cloned row comes from ``isInRotation(asOf:timeZone:)``
    /// / ``rotationCohort`` on the `CatalogRow` itself, not from this bridge.
    var detailFallback: AlbumSearchResult {
        .headerStandIn(
            id: id,
            albumTitle: albumTitle,
            artistName: artistName,
            codeLetters: codeLetters,
            codeNumber: codeNumber,
            codeArtistNumber: codeArtistNumber,
            formatName: formatName,
            genreName: genreName,
            label: label,
            plays: plays,
            onStreaming: onStreaming,
            artworkURL: artworkURL
        )
    }
}
