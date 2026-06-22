//
//  CatalogRow.swift
//  WXYCAPI
//
//  Decoded shape of one row from Backend-Service GET /library/catalog — the
//  bulk catalog export the on-device Spotlight clone mirrors (issue #19).
//  Distinct from AlbumSearchResult: raw rotation + a kill date, no search
//  decoration. See docs/library-row-type-contract.md.
//
//  Created by Jake on 06/22/26.
//  Copyright © 2026 WXYC. All rights reserved.
//

import Foundation

/// One row of the WXYC library catalog as served by `GET /library/catalog`
/// (BS#1468) for offline cloning — a query-independent snapshot of the core
/// catalog row.
///
/// `CatalogRow` is deliberately **not** ``AlbumSearchResult``. The export drops
/// the search-only decoration (`matched_via`, `album_dist`, …) and the columns
/// the projection omits (`add_date`, `label_id`, `rotation_id`, `album_artist`,
/// `date_lost`, `date_found`), and ships rotation **raw**: ``rotationBin`` is the
/// most-recent rotation record, *not* the `CURRENT_DATE`-filtered value
/// ``AlbumSearchResult/rotationBin`` carries, paired with ``rotationKillDate`` so
/// the client evaluates expiry against its own clock (``isInRotation(today:)``).
/// Reusing `AlbumSearchResult` here would silently drop `rotation_kill_date` and
/// stamp filtered-rotation semantics onto raw data — see
/// `docs/library-row-type-contract.md`.
public struct CatalogRow: Codable, Sendable, Hashable, Identifiable {
    public let id: Int
    public let artistName: String
    public let albumTitle: String
    public let codeLetters: String?
    public let codeNumber: Int?
    public let codeArtistNumber: Int?
    public let label: String?
    public let genreName: String?
    public let formatName: String?
    public let onStreaming: Bool?
    public let plays: Int?
    public let artworkURL: URL?

    /// Raw current-rotation bin — **not** `CURRENT_DATE`-filtered. Decoded
    /// tolerantly: a legacy/unknown wire value (e.g. `"N"`) becomes `nil` rather
    /// than failing the whole row. Evaluate live rotation with
    /// ``isInRotation(today:)``, never by reading this in isolation.
    public let rotationBin: RotationBin?

    /// Date the current rotation record expires, as the raw `"YYYY-MM-DD"` the
    /// server emits (a deliberate `::text` cast — a stable calendar date, not a
    /// parser-dependent instant). Kept as a string so expiry is a timezone-free
    /// lexicographic compare. `nil` when the record has no kill date.
    public let rotationKillDate: String?

    public init(
        id: Int,
        artistName: String,
        albumTitle: String,
        codeLetters: String?,
        codeNumber: Int?,
        codeArtistNumber: Int?,
        label: String?,
        genreName: String?,
        formatName: String?,
        onStreaming: Bool?,
        plays: Int?,
        artworkURL: URL?,
        rotationBin: RotationBin?,
        rotationKillDate: String?
    ) {
        self.id = id
        self.artistName = artistName
        self.albumTitle = albumTitle
        self.codeLetters = codeLetters
        self.codeNumber = codeNumber
        self.codeArtistNumber = codeArtistNumber
        self.label = label
        self.genreName = genreName
        self.formatName = formatName
        self.onStreaming = onStreaming
        self.plays = plays
        self.artworkURL = artworkURL
        self.rotationBin = rotationBin
        self.rotationKillDate = rotationKillDate
    }

    enum CodingKeys: String, CodingKey {
        case id
        case artistName = "artist_name"
        case albumTitle = "album_title"
        case codeLetters = "code_letters"
        case codeNumber = "code_number"
        case codeArtistNumber = "code_artist_number"
        case label
        case genreName = "genre_name"
        case formatName = "format_name"
        case onStreaming = "on_streaming"
        case plays
        case artworkURL = "artwork_url"
        case rotationBin = "rotation_bin"
        case rotationKillDate = "rotation_kill_date"
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(Int.self, forKey: .id)
        artistName = try c.decode(String.self, forKey: .artistName)
        albumTitle = try c.decode(String.self, forKey: .albumTitle)
        codeLetters = try c.decodeIfPresent(String.self, forKey: .codeLetters)
        codeNumber = try c.decodeIfPresent(Int.self, forKey: .codeNumber)
        codeArtistNumber = try c.decodeIfPresent(Int.self, forKey: .codeArtistNumber)
        label = try c.decodeIfPresent(String.self, forKey: .label)
        genreName = try c.decodeIfPresent(String.self, forKey: .genreName)
        formatName = try c.decodeIfPresent(String.self, forKey: .formatName)
        onStreaming = try c.decodeIfPresent(Bool.self, forKey: .onStreaming)
        plays = try c.decodeIfPresent(Int.self, forKey: .plays)
        artworkURL = try c.decodeIfPresent(URL.self, forKey: .artworkURL)
        // Raw rotation may carry legacy codes (e.g. 'N'); decode tolerantly to
        // nil rather than failing the row. Mirrors AlbumSearchResult.
        rotationBin = (try? c.decodeIfPresent(RotationBin.self, forKey: .rotationBin)) ?? nil
        rotationKillDate = try c.decodeIfPresent(String.self, forKey: .rotationKillDate)
    }

    /// Shelf call number, e.g. `"MOL 1/12"`. Reuses ``AlbumSearchResult``'s
    /// formatter so the search and catalog surfaces render shelf codes
    /// identically (same core entity, one formatting rule).
    public var callNumber: String {
        AlbumSearchResult.formatCallNumber(
            letters: codeLetters,
            artistNumber: codeArtistNumber,
            releaseNumber: codeNumber
        )
    }

    /// Whether this row is in rotation as of `today` — the client's local
    /// calendar day as a `"YYYY-MM-DD"` string (see ``localToday(now:timeZone:)``).
    ///
    /// The export ships rotation **raw**, so expiry is the client's job: a row
    /// is in rotation iff a bin is set **and** the kill date is absent or still
    /// in the future. Zero-padded ISO dates sort chronologically, so this is a
    /// plain string compare — no `Date` parsing and no timezone ambiguity — and
    /// an exact match for the server's `kill_date > CURRENT_DATE` filter (strict
    /// greater-than: a record expiring *today* is already out).
    public func isInRotation(today: String) -> Bool {
        guard rotationBin != nil else { return false }
        guard let rotationKillDate else { return true }
        return rotationKillDate > today
    }

    /// The calendar day of `now` in `timeZone`, formatted as a zero-padded
    /// `"YYYY-MM-DD"` string suitable for ``isInRotation(today:)``. Pinned to
    /// `en_US_POSIX` and an explicit time zone so the result never drifts with
    /// host locale/calendar settings. Compute once, then pass to
    /// ``isInRotation(today:)`` per row.
    public static func localToday(now: Date = Date(), timeZone: TimeZone = .current) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = timeZone
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: now)
    }
}
