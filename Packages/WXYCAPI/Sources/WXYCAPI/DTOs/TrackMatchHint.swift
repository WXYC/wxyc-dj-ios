//
//  TrackMatchHint.swift
//  WXYCAPI
//
//  Optional provenance attached to library search rows when the row was
//  surfaced by a track-title match rather than a hit on artist or album.
//  Empty / absent on a normal artist+album hit. Mirrors the TrackMatchHint
//  + TrackMatchSource schemas in wxyc-shared/api.yaml.
//
//  Created by Jake on 5/20/26.
//  Copyright © 2026 WXYC. All rights reserved.
//

import Foundation

public struct TrackMatchHint: Decodable, Sendable, Hashable {
    public let title: String
    public let artistCredit: String?
    public let position: String?
    public let confidence: Double?
    public let source: TrackMatchSource

    enum CodingKeys: String, CodingKey {
        case title
        case artistCredit = "artist_credit"
        case position
        case confidence
        case source
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        title = try c.decode(String.self, forKey: .title)
        artistCredit = try c.decodeIfPresent(String.self, forKey: .artistCredit)
        position = try c.decodeIfPresent(String.self, forKey: .position)
        confidence = try c.decodeIfPresent(Double.self, forKey: .confidence)
        // Unknown TrackMatchSource values are decoded as `.unknown` rather
        // than failing the row. Server adds new sources as cross-cache-
        // identity work lands; the client must not start refusing rows.
        source = (try? c.decode(TrackMatchSource.self, forKey: .source)) ?? .unknown
    }
}

public enum TrackMatchSource: String, Decodable, Sendable, Hashable, CaseIterable {
    case cta
    case discogsRelease = "discogs_release"
    case discogsMaster = "discogs_master"
    case libraryIdentity = "library_identity"
    case unknown
}
