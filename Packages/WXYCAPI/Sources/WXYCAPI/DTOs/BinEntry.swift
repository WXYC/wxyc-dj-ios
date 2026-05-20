//
//  BinEntry.swift
//  WXYCAPI
//
//  Decoded shape of a row in the DJ's personal bin
//  (GET /djs/bin → DJBinResponse.entries). Mirrors BinEntry in api.yaml.
//
//  Created by Jake on 5/14/26.
//  Copyright © 2026 WXYC. All rights reserved.
//

import Foundation

public struct BinEntry: Codable, Sendable, Hashable, Identifiable {
    public let id: Int
    public let djId: Int
    public let albumId: Int
    public let addedAt: Date
    public let albumTitle: String
    public let artistName: String
    public let codeLetters: String
    public let codeNumber: Int

    /// `<letters> <number>` — BinEntry doesn't carry the artist code today,
    /// so this is shorter than AlbumSearchResult.callNumber.
    public var callNumber: String {
        AlbumSearchResult.formatCallNumber(letters: codeLetters, artistNumber: nil, releaseNumber: codeNumber)
    }

    enum CodingKeys: String, CodingKey {
        case id
        case djId = "dj_id"
        case albumId = "album_id"
        case addedAt = "added_at"
        case albumTitle = "album_title"
        case artistName = "artist_name"
        case codeLetters = "code_letters"
        case codeNumber = "code_number"
    }
}

public struct DJBinResponse: Codable, Sendable, Hashable {
    public let djId: Int
    public let entries: [BinEntry]

    enum CodingKeys: String, CodingKey {
        case djId = "dj_id"
        case entries
    }
}
