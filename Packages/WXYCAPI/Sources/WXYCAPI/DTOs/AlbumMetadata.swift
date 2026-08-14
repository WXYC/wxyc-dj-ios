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
//  Deliberately kept hand-authored, not generated (issue #75) — and not the
//  "exact-name match" it looks like at first glance. Two separate problems:
//  (1) api.yaml's schema for this exact endpoint is named
//  `AlbumMetadataResponse`, not `AlbumMetadata` — the api.yaml schema
//  literally called `AlbumMetadata` is an unrelated, much smaller shape used
//  elsewhere (album_id/artwork_url/discogs_url/release_year/last_fetched
//  only, no genres/styles/tracklist). (2) Even against the correctly-named
//  `AlbumMetadataResponse`, the generated type has no `artistBio` /
//  `artistWikipediaUrl` fields — `artistWikipediaURL` is actively rendered
//  in AlbumDetailView.swift (the "Wikipedia" external link), so aliasing to
//  the generated type would either fail to compile at that call site or,
//  worse, require deleting a live UI feature to make it compile. Until
//  wxyc-shared's `AlbumMetadataResponse` schema grows those two fields (the
//  schema's own doc comment already acknowledges a similar undeclared-field
//  gap for `artistName`/`releaseTitle`/`trackTitle`), this stays hand-written.
//  See CLAUDE.md's "Code Generation" section.
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
