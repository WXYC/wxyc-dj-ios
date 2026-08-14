//
//  AlbumInfo.swift
//  WXYCAPI
//
//  Decoded shape of GET /library/info?album_id=X.
//  Mirrors the AlbumInfoResponse schema in wxyc-shared/api.yaml — an Album
//  plus denormalized artist/code/format/genre and an optional rotation block.
//
//  Deliberately kept hand-authored, not generated (issue #75). Two reasons:
//  (1) the same required-vs-nullable gap as BinEntry/AlbumSearchResult —
//  `AlbumInfoResponse` marks `code_letters` / `format_name` / `artist_name`
//  `required` without `nullable: true`, while real V/A / unfiled catalog
//  rows carry nulls for the code fields; (2) it needs to try both `label`
//  and `record_label` wire keys (`/library/info` uses the latter, the
//  catalog list endpoint the former), a dual-key fallback a generated
//  `Codable` can't express. `AlbumInfoResponse` is also an OpenAPI `allOf`
//  composite over `Album`, which the generator would need to flatten or
//  wrap — added complexity on top of the two problems above. See
//  CLAUDE.md's "Code Generation" section.
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
        public let rotationBin: RotationBin
        public let addDate: Date
        public let killDate: Date?

        enum CodingKeys: String, CodingKey {
            case id
            case rotationBin = "rotation_bin"
            case addDate = "add_date"
            case killDate = "kill_date"
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
