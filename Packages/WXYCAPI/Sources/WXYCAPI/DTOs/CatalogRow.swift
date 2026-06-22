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
/// most-recent rotation record's bin verbatim, *not* the `CURRENT_DATE`-filtered
/// value ``AlbumSearchResult`` carries, paired with ``rotationKillDate`` so the
/// client evaluates expiry against its own clock (``isInRotation(asOf:timeZone:)``).
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

    /// Raw current-rotation bin verbatim from the most-recent rotation record —
    /// **not** `CURRENT_DATE`-filtered. The server enumerates `S`/`L`/`M`/`H`/`N`
    /// (Backend-Service `app.yaml` `CatalogExportRow`), of which only `H`/`M`/`L`/`S`
    /// are the DJ-facing display cohorts (see ``rotationCohort``); `"N"` and any
    /// future value are still *valid rotation* per the server's predicate. Kept
    /// as the raw string (not the ``RotationBin`` enum) precisely so a non-cohort
    /// value is preserved rather than collapsed to `nil` — collapsing it would
    /// make ``isInRotation(asOf:timeZone:)`` wrongly report an `"N"` row as out of
    /// rotation. `nil` means the album has no rotation record. Evaluate rotation
    /// state with ``isInRotation(asOf:timeZone:)``, never by reading this directly.
    public let rotationBin: String?

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
        rotationBin: String?,
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
        // artwork_url is free-text typed `string | null`; a legacy empty string
        // (or any malformed value) maps to nil rather than throwing and failing
        // the WHOLE row — the full-catalog NDJSON clone must not drop a row over
        // one dirty URL. Decode the raw string and build the URL ourselves.
        artworkURL = (try c.decodeIfPresent(String.self, forKey: .artworkURL))
            .flatMap { $0.isEmpty ? nil : URL(string: $0) }
        // Raw bin verbatim — preserves "N" and any future server value (see the
        // rotationBin doc). null/absent decode to nil.
        rotationBin = try c.decodeIfPresent(String.self, forKey: .rotationBin)
        rotationKillDate = try c.decodeIfPresent(String.self, forKey: .rotationKillDate)
    }

    /// The DJ-facing display cohort (`H`/`M`/`L`/`S`) for ``rotationBin``, or
    /// `nil` when there is no bin **or** the raw bin is outside those cohorts
    /// (e.g. `"N"`). A row can be in rotation (``isInRotation(asOf:timeZone:)``)
    /// yet have no display cohort — use this only for labelling, not rotation state.
    public var rotationCohort: RotationBin? {
        rotationBin.flatMap(RotationBin.init(rawValue:))
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

    /// Whether this row is in rotation as of `now` in `timeZone` (defaults: the
    /// device's current clock). Mirrors the server's published predicate for the
    /// raw export — `rotation_bin != null && (rotation_kill_date == null ||
    /// rotation_kill_date > today)` — evaluated against the client's local
    /// calendar day, because the export defers daily kill-date expiry to the
    /// client. **Any** non-null bin counts as in rotation, including non-cohort
    /// values like `"N"`; the kill-date comparison is strict (a record expiring
    /// *today* is already out), matching the server's `kill_date > CURRENT_DATE`.
    public func isInRotation(asOf now: Date = Date(), timeZone: TimeZone = .current) -> Bool {
        isInRotation(localDay: Self.localDay(now, timeZone: timeZone))
    }

    /// Pure core of ``isInRotation(asOf:timeZone:)``. `today` MUST be a
    /// zero-padded `"YYYY-MM-DD"` local day (the output of ``localDay(_:timeZone:)``);
    /// the lexicographic kill-date compare is only equivalent to a chronological
    /// one for that fixed-width form. Kept `internal` so external callers can't
    /// pass a malformed string — they go through ``isInRotation(asOf:timeZone:)``,
    /// which builds `today` correctly. Batch callers compute the day once with
    /// ``localDay(_:timeZone:)`` and reuse it across rows.
    func isInRotation(localDay today: String) -> Bool {
        guard rotationBin != nil else { return false }
        guard let rotationKillDate else { return true }
        return rotationKillDate > today
    }

    /// The calendar day of `now` in `timeZone` as a zero-padded `"YYYY-MM-DD"`
    /// string. Pinned to `en_US_POSIX` + an explicit time zone so the result
    /// never drifts with host locale/calendar settings.
    static func localDay(_ now: Date = Date(), timeZone: TimeZone = .current) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = timeZone
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: now)
    }
}
