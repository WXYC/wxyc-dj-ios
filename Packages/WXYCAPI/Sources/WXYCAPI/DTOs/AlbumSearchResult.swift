//
//  AlbumSearchResult.swift
//  WXYCAPI
//
//  Decoded shape of a row returned by Backend-Service GET /library/.
//  Mirrors the AlbumSearchResult schema in wxyc-shared/api.yaml.
//
//  Created by Jake on 5/14/26.
//  Copyright © 2026 WXYC. All rights reserved.
//

import Foundation

public struct AlbumSearchResult: Codable, Sendable, Hashable, Identifiable {
    public let id: Int
    public let addDate: Date?
    public let albumTitle: String
    public let artistName: String
    public let codeLetters: String?
    public let codeNumber: Int?
    public let codeArtistNumber: Int?
    public let formatName: String?
    public let genreName: String?
    public let label: String?
    public let labelId: Int?
    public let rotationBin: RotationBin?
    public let rotationId: Int?
    public let plays: Int?
    public let onStreaming: Bool?
    public let albumArtist: String?
    public let artworkURL: URL?

    enum CodingKeys: String, CodingKey {
        case id
        case addDate = "add_date"
        case albumTitle = "album_title"
        case artistName = "artist_name"
        case codeLetters = "code_letters"
        case codeNumber = "code_number"
        case codeArtistNumber = "code_artist_number"
        case formatName = "format_name"
        case genreName = "genre_name"
        case label
        case labelId = "label_id"
        case rotationBin = "rotation_bin"
        case rotationId = "rotation_id"
        case plays
        case onStreaming = "on_streaming"
        case albumArtist = "album_artist"
        case artworkURL = "artwork_url"
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(Int.self, forKey: .id)
        addDate = try c.decodeIfPresent(Date.self, forKey: .addDate)
        albumTitle = try c.decode(String.self, forKey: .albumTitle)
        artistName = try c.decode(String.self, forKey: .artistName)
        codeLetters = try c.decodeIfPresent(String.self, forKey: .codeLetters)
        codeNumber = try c.decodeIfPresent(Int.self, forKey: .codeNumber)
        codeArtistNumber = try c.decodeIfPresent(Int.self, forKey: .codeArtistNumber)
        formatName = try c.decodeIfPresent(String.self, forKey: .formatName)
        genreName = try c.decodeIfPresent(String.self, forKey: .genreName)
        label = try c.decodeIfPresent(String.self, forKey: .label)
        labelId = try c.decodeIfPresent(Int.self, forKey: .labelId)
        // Unknown rotation_bin values (e.g. the legacy 'N') are decoded as nil
        // rather than blowing up the row.
        rotationBin = (try? c.decodeIfPresent(RotationBin.self, forKey: .rotationBin)) ?? nil
        rotationId = try c.decodeIfPresent(Int.self, forKey: .rotationId)
        plays = try c.decodeIfPresent(Int.self, forKey: .plays)
        onStreaming = try c.decodeIfPresent(Bool.self, forKey: .onStreaming)
        albumArtist = try c.decodeIfPresent(String.self, forKey: .albumArtist)
        artworkURL = try c.decodeIfPresent(URL.self, forKey: .artworkURL)
    }

    /// Shelf call number in the form "<codeLetters> <codeArtistNumber>/<codeNumber>"
    /// (e.g. "AU 3/2"). Any leg that's missing on the wire is dropped so we
    /// never render an Optional() literal.
    public var callNumber: String {
        Self.formatCallNumber(letters: codeLetters, artistNumber: codeArtistNumber, releaseNumber: codeNumber)
    }

    static func formatCallNumber(letters: String?, artistNumber: Int?, releaseNumber: Int?) -> String {
        var parts: [String] = []
        if let letters, !letters.isEmpty { parts.append(letters) }
        switch (artistNumber, releaseNumber) {
        case let (a?, r?): parts.append("\(a)/\(r)")
        case let (a?, nil): parts.append("\(a)")
        case let (nil, r?): parts.append("\(r)")
        case (nil, nil): break
        }
        return parts.joined(separator: " ")
    }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encodeIfPresent(addDate, forKey: .addDate)
        try c.encode(albumTitle, forKey: .albumTitle)
        try c.encode(artistName, forKey: .artistName)
        try c.encodeIfPresent(codeLetters, forKey: .codeLetters)
        try c.encodeIfPresent(codeNumber, forKey: .codeNumber)
        try c.encodeIfPresent(codeArtistNumber, forKey: .codeArtistNumber)
        try c.encodeIfPresent(formatName, forKey: .formatName)
        try c.encodeIfPresent(genreName, forKey: .genreName)
        try c.encodeIfPresent(label, forKey: .label)
        try c.encodeIfPresent(labelId, forKey: .labelId)
        try c.encodeIfPresent(rotationBin, forKey: .rotationBin)
        try c.encodeIfPresent(rotationId, forKey: .rotationId)
        try c.encodeIfPresent(plays, forKey: .plays)
        try c.encodeIfPresent(onStreaming, forKey: .onStreaming)
        try c.encodeIfPresent(albumArtist, forKey: .albumArtist)
        try c.encodeIfPresent(artworkURL, forKey: .artworkURL)
    }
}

public enum RotationBin: String, Codable, Sendable, Hashable, CaseIterable {
    case heavy = "H"
    case medium = "M"
    case light = "L"
    case single = "S"

    public var label: String {
        switch self {
        case .heavy: "Heavy"
        case .medium: "Medium"
        case .light: "Light"
        case .single: "Single"
        }
    }
}
