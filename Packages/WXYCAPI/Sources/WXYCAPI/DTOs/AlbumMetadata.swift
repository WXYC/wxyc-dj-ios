//
//  AlbumMetadata.swift
//  WXYCAPI
//
//  Wire shape of GET /proxy/metadata/album. Backend-Service composes the
//  response from LML's lookup + release endpoints; every field is optional
//  because LML coverage is partial (some artists have no Discogs match, some
//  releases have no tracklist, etc.). All keys are top-level camelCase —
//  matches proxy.controller.ts's serializer, not the snake_case library
//  catalog shape.
//
//  Created by Jake on 5/14/26.
//  Copyright © 2026 WXYC. All rights reserved.
//

import Foundation

public struct AlbumMetadata: Codable, Sendable, Hashable {
    public let discogsReleaseId: Int?
    public let discogsArtistId: Int?
    public let discogsURL: URL?
    public let artworkURL: URL?
    public let releaseYear: Int?
    public let fullReleaseDate: String?
    public let label: String?
    public let genres: [String]?
    public let styles: [String]?
    public let artistBio: String?
    public let artistWikipediaURL: URL?
    public let spotifyURL: URL?
    public let appleMusicURL: URL?
    public let youtubeMusicURL: URL?
    public let bandcampURL: URL?
    public let soundcloudURL: URL?
    public let tracklist: [Track]?

    public struct Track: Codable, Sendable, Hashable, Identifiable {
        public let position: String
        public let title: String
        public let duration: String?

        public var id: String { "\(position)|\(title)" }
    }

    enum CodingKeys: String, CodingKey {
        case discogsReleaseId, discogsArtistId
        case discogsURL = "discogsUrl"
        case artworkURL = "artworkUrl"
        case releaseYear, fullReleaseDate, label, genres, styles, artistBio
        case artistWikipediaURL = "artistWikipediaUrl"
        case spotifyURL = "spotifyUrl"
        case appleMusicURL = "appleMusicUrl"
        case youtubeMusicURL = "youtubeMusicUrl"
        case bandcampURL = "bandcampUrl"
        case soundcloudURL = "soundcloudUrl"
        case tracklist
    }
}

public enum StreamingService: String, Sendable, CaseIterable {
    case spotify, appleMusic, youtubeMusic, bandcamp, soundcloud

    public var label: String {
        switch self {
        case .spotify: "Spotify"
        case .appleMusic: "Apple Music"
        case .youtubeMusic: "YouTube Music"
        case .bandcamp: "Bandcamp"
        case .soundcloud: "SoundCloud"
        }
    }

    public var symbolName: String {
        switch self {
        case .spotify, .appleMusic, .youtubeMusic, .soundcloud: "music.note"
        case .bandcamp: "b.circle"
        }
    }

    public func url(in metadata: AlbumMetadata) -> URL? {
        switch self {
        case .spotify: metadata.spotifyURL
        case .appleMusic: metadata.appleMusicURL
        case .youtubeMusic: metadata.youtubeMusicURL
        case .bandcamp: metadata.bandcampURL
        case .soundcloud: metadata.soundcloudURL
        }
    }
}
