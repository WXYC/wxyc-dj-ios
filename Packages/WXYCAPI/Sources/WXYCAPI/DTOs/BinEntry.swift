//
//  BinEntry.swift
//  WXYCAPI
//
//  Decoded shape of a row in the DJ's personal bin (GET /djs/bin, which
//  returns a bare array): the denormalized library join Backend-Service
//  actually emits. Modelled on the *handler projection*, not on api.yaml —
//  today it is a superset of api.yaml's BinLibraryDetails, which doesn't yet
//  declare `alphabetical_name`. Interim: WXYC/wxyc-shared#344 points the 200 at
//  an array of BinLibraryDetails and adds that field; #359 covers POST/DELETE.
//
//  Deliberately kept hand-authored, not generated (issue #75). NOT for the
//  same required-vs-nullable gap cited for AlbumSearchResult in an earlier
//  version of this comment — that framing doesn't hold here either (see
//  AlbumSearchResult.swift's doc comment for why the "V/A rows carry NULL"
//  premise is false in general). `code_letters` / `code_number` are kept
//  optional below defensively, and `decodesBinEntryWithNullCallNumberLegs`
//  stays as a regression test, but that's not the load-bearing reason.
//
//  The real, more decisive reason: `GET /djs/bin` doesn't emit `id`,
//  `dj_id`, or `added_at` AT ALL. `DJService.getBinFromDB` (djs.service.ts)
//  selects `album_id, album_title, artist_name, alphabetical_name, label,
//  code_letters, code_artist_number, code_number, format_name, genre_name,
//  legacy_release_id` — none of those three keys. api.yaml's `BinEntry`
//  schema marks `id` / `dj_id` / `added_at` `required`, so the generated
//  WXYCAPIModels.BinEntry declares them non-optional — decoding the real
//  `GET /djs/bin` response would throw `keyNotFound` on every single entry,
//  not just ones with an edge-case null. See CLAUDE.md's "Code Generation"
//  section.
//
//  Created by Jake on 5/14/26.
//  Copyright © 2026 WXYC. All rights reserved.
//

import Foundation

/// One release in the DJ's bin, as projected by `djs.service.getBinFromDB` —
/// the `bins` row joined out to `library` / `artists` / `format` / `genres`.
///
/// The wire carries **no** `bins.id`, `dj_id`, or added-at timestamp: the
/// projection is library data only (`bins` has no timestamp column at all), and
/// `DELETE /djs/bin` removes every row for a `(dj, album)` pair. `albumId` is
/// therefore the bin's effective key, and is what ``id`` reports.
public struct BinEntry: Codable, Sendable, Hashable, Identifiable {
    /// The library row's id. See the type's note on why this is the bin's key
    /// rather than a per-row bin identifier.
    public var id: Int { albumId }

    public let albumId: Int
    public let albumTitle: String
    public let artistName: String
    /// Filing form of `artistName` ("Molina, Juana"). `NOT NULL` upstream, but
    /// optional here so a projection change can't fail the whole row; it only
    /// drives sort order, which falls back to `artistName`.
    public let alphabeticalName: String?
    public let label: String?
    // The call-number legs are nullable in the catalog (V/A compilations,
    // unfiled adds), so keep them optional to match AlbumSearchResult.
    public let codeLetters: String?
    public let codeArtistNumber: Int?
    public let codeNumber: Int?
    public let formatName: String?
    public let genreName: String?

    public init(
        albumId: Int,
        albumTitle: String,
        artistName: String,
        alphabeticalName: String? = nil,
        label: String? = nil,
        codeLetters: String? = nil,
        codeArtistNumber: Int? = nil,
        codeNumber: Int? = nil,
        formatName: String? = nil,
        genreName: String? = nil
    ) {
        self.albumId = albumId
        self.albumTitle = albumTitle
        self.artistName = artistName
        self.alphabeticalName = alphabeticalName
        self.label = label
        self.codeLetters = codeLetters
        self.codeArtistNumber = codeArtistNumber
        self.codeNumber = codeNumber
        self.formatName = formatName
        self.genreName = genreName
    }

    /// Shelf call number in the form `<letters> <artistNumber>/<releaseNumber>`
    /// (e.g. "MOL 1/12") — the same rendering as ``AlbumSearchResult/callNumber``,
    /// since the bin projection carries all three legs.
    public var callNumber: String {
        AlbumSearchResult.formatCallNumber(
            letters: codeLetters,
            artistNumber: codeArtistNumber,
            releaseNumber: codeNumber
        )
    }

    /// Key the bin sorts on: the librarian's filing name, falling back to the
    /// display name when the projection omits it.
    public var sortName: String { alphabeticalName ?? artistName }

    /// Collapse rows that address the same album, keeping first-seen order.
    ///
    /// **Required before any ``BinStore/saveSnapshot(_:)``.** The store is keyed
    /// by album id (`bin(id INTEGER PRIMARY KEY)`) and inserts with a plain
    /// `INSERT`, so a duplicate raises `SQLITE_CONSTRAINT` and rolls back the
    /// *entire* save — one repeated row costs the whole offline bin. It lives
    /// here, next to that invariant, rather than in a view model: the wire can
    /// genuinely repeat an album (the `/djs/bin` projection omits `track_title`,
    /// so an album binned under two tracks arrives twice, and `DELETE /djs/bin`
    /// clears the album wholesale — they are one row to every reader), and the
    /// issue-#61 pending-intention writer will need the same collapse when it
    /// merges queued adds into a snapshot.
    public static func deduplicatedByAlbum(_ entries: [BinEntry]) -> [BinEntry] {
        var seen: Set<Int> = []
        return entries.filter { seen.insert($0.albumId).inserted }
    }

    enum CodingKeys: String, CodingKey {
        case albumId = "album_id"
        case albumTitle = "album_title"
        case artistName = "artist_name"
        case alphabeticalName = "alphabetical_name"
        case label
        case codeLetters = "code_letters"
        case codeArtistNumber = "code_artist_number"
        case codeNumber = "code_number"
        case formatName = "format_name"
        case genreName = "genre_name"
    }
}
