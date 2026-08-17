//
//  AlbumInfo.swift
//  WXYCAPI
//
//  Decoded shape of GET /library/info?album_id=X.
//  Mirrors the AlbumInfoResponse schema in wxyc-shared/api.yaml — an Album
//  plus denormalized artist/code/format/genre and an optional rotation block.
//
//  Deliberately kept hand-authored, not generated (issue #75). Two reasons,
//  neither of them the required-vs-nullable gap an earlier version of this
//  comment cited (see AlbumSearchResult.swift's doc comment for why that
//  premise doesn't hold in general): (1) the generated `AlbumInfoResponse`
//  is missing `code_artist_number`, `plays`, `on_streaming`, and
//  `artwork_url` outright — they're absent from api.yaml's `Album` /
//  `AlbumInfoResponse` schemas, not merely optional — and `AlbumDetailView.swift`
//  reads all four (`info.artworkURL`, `info.plays`, `info.onStreaming`
//  directly; `codeArtistNumber` feeds `callNumber` below); (2) it needs to
//  try both `label` and `record_label` wire keys (`/library/info` uses the
//  latter, the catalog list endpoint the former), a dual-key fallback a
//  generated `Codable` can't express. (`AlbumInfoResponse` is an OpenAPI
//  `allOf` composite over `Album`, but the generator flattens that into one
//  clean struct without help — not itself a reason to stay hand-authored.)
//  See CLAUDE.md's "Code Generation" section.
//
//  Created by Jake on 5/14/26.
//  Copyright © 2026 WXYC. All rights reserved.
//

import Foundation

public struct AlbumInfo: Codable, Sendable, Hashable, Identifiable {
    public let id: Int
    public let artistId: Int?
    public let albumTitle: String
    public let codeNumber: Int?
    public let codeLetters: String?
    public let codeArtistNumber: Int?
    public let artistName: String
    public let formatName: String?
    public let genreName: String?
    public let label: String?
    public let labelId: Int?
    public let addDate: Date?
    public let discQuantity: Int?
    public let alternateArtistName: String?
    public let albumArtist: String?
    public let plays: Int?
    public let onStreaming: Bool?
    public let artworkURL: URL?
    public let rotation: Rotation?

    public var callNumber: String {
        AlbumSearchResult.formatCallNumber(letters: codeLetters, artistNumber: codeArtistNumber, releaseNumber: codeNumber)
    }

    public struct Rotation: Codable, Sendable, Hashable {
        public let id: Int

        /// Raw current-rotation bin verbatim from the wire — **not** the closed
        /// ``RotationBin`` enum. Kept as the raw string as the same
        /// forward-compatibility hedge ``CatalogRow/rotationBin`` documents: a
        /// bin added server-side ahead of this app must not fail the whole
        /// `AlbumInfo` decode (issue #93). A *present* `rotation` object always
        /// carries a bin — unlike `CatalogRow`, there's no "no rotation record"
        /// case to represent here, since the surrounding `rotation` key is
        /// itself optional for that — so this is non-optional, matching the
        /// wire's `required` `rotation_bin`.
        public let rotationBin: String
        public let addDate: Date
        public let killDate: Date?

        enum CodingKeys: String, CodingKey {
            case id
            case rotationBin = "rotation_bin"
            case addDate = "add_date"
            case killDate = "kill_date"
        }

        /// The DJ-facing display cohort (`H`/`M`/`L`/`S`) for ``rotationBin``, or
        /// `nil` when the raw bin is outside those cohorts — the case
        /// ``rotationBin`` is deliberately typed to survive. Mirrors
        /// ``CatalogRow/rotationCohort``; use this only for labelling.
        public var rotationCohort: RotationBin? {
            RotationBin(rawValue: rotationBin)
        }
    }

    enum CodingKeys: String, CodingKey {
        case id
        case artistId = "artist_id"
        case albumTitle = "album_title"
        case codeNumber = "code_number"
        case codeLetters = "code_letters"
        case codeArtistNumber = "code_artist_number"
        case artistName = "artist_name"
        case formatName = "format_name"
        case genreName = "genre_name"
        // /library/info uses `record_label`; the catalog list endpoint uses
        // `label`. Accept either by trying both keys in init(from:).
        case label
        case recordLabel = "record_label"
        case labelId = "label_id"
        case addDate = "add_date"
        case discQuantity = "disc_quantity"
        case alternateArtistName = "alternate_artist_name"
        case albumArtist = "album_artist"
        case plays
        case onStreaming = "on_streaming"
        case artworkURL = "artwork_url"
        case rotation
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(Int.self, forKey: .id)
        artistId = try c.decodeIfPresent(Int.self, forKey: .artistId)
        albumTitle = try c.decode(String.self, forKey: .albumTitle)
        codeNumber = try c.decodeIfPresent(Int.self, forKey: .codeNumber)
        codeLetters = try c.decodeIfPresent(String.self, forKey: .codeLetters)
        codeArtistNumber = try c.decodeIfPresent(Int.self, forKey: .codeArtistNumber)
        artistName = try c.decode(String.self, forKey: .artistName)
        formatName = try c.decodeIfPresent(String.self, forKey: .formatName)
        genreName = try c.decodeIfPresent(String.self, forKey: .genreName)
        label = try c.decodeIfPresent(String.self, forKey: .label)
            ?? c.decodeIfPresent(String.self, forKey: .recordLabel)
        labelId = try c.decodeIfPresent(Int.self, forKey: .labelId)
        addDate = try c.decodeIfPresent(Date.self, forKey: .addDate)
        discQuantity = try c.decodeIfPresent(Int.self, forKey: .discQuantity)
        alternateArtistName = try c.decodeIfPresent(String.self, forKey: .alternateArtistName)
        albumArtist = try c.decodeIfPresent(String.self, forKey: .albumArtist)
        plays = try c.decodeIfPresent(Int.self, forKey: .plays)
        onStreaming = try c.decodeIfPresent(Bool.self, forKey: .onStreaming)
        artworkURL = try c.decodeIfPresent(URL.self, forKey: .artworkURL)
        rotation = try c.decodeIfPresent(Rotation.self, forKey: .rotation)
    }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encodeIfPresent(artistId, forKey: .artistId)
        try c.encode(albumTitle, forKey: .albumTitle)
        try c.encodeIfPresent(codeNumber, forKey: .codeNumber)
        try c.encodeIfPresent(codeLetters, forKey: .codeLetters)
        try c.encodeIfPresent(codeArtistNumber, forKey: .codeArtistNumber)
        try c.encode(artistName, forKey: .artistName)
        try c.encodeIfPresent(formatName, forKey: .formatName)
        try c.encodeIfPresent(genreName, forKey: .genreName)
        try c.encodeIfPresent(label, forKey: .label)
        try c.encodeIfPresent(labelId, forKey: .labelId)
        try c.encodeIfPresent(addDate, forKey: .addDate)
        try c.encodeIfPresent(discQuantity, forKey: .discQuantity)
        try c.encodeIfPresent(alternateArtistName, forKey: .alternateArtistName)
        try c.encodeIfPresent(albumArtist, forKey: .albumArtist)
        try c.encodeIfPresent(plays, forKey: .plays)
        try c.encodeIfPresent(onStreaming, forKey: .onStreaming)
        try c.encodeIfPresent(artworkURL, forKey: .artworkURL)
        try c.encodeIfPresent(rotation, forKey: .rotation)
    }
}
