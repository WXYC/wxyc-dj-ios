//
//  CatalogRow.swift
//  WXYCAPI
//
//  Decoded shape of one row from Backend-Service GET /library/catalog — the
//  bulk catalog export the on-device Spotlight clone mirrors (issue #19).
//  Distinct from AlbumSearchResult: raw rotation + a kill date, no search
//  decoration. See docs/library-row-type-contract.md.
//
//  Deliberately kept hand-authored, not generated (issue #75) — and not
//  actually schema-less, despite the name mismatch suggesting otherwise.
//  docs/library-row-type-contract.md was written when `/library/catalog`'s
//  wire shape lived only as Backend-Service's private `CatalogExportRow`
//  TypeScript type, absent from api.yaml; that gap has since closed —
//  api.yaml now has a `CatalogExportRow` schema (BS#1468/#1965).
//
//  An earlier version of this comment cited that schema's own doc comment
//  as a warning that its `required` fields "would fail EVERY NDJSON line
//  and take the whole on-device clone with it" if decoded strictly — that
//  misquotes it. The warning is about a schema author accidentally adding a
//  NEW required response property in the future (`oasdiff` doesn't flag
//  that as breaking, so a green `check:breaking` wouldn't catch it before
//  it ships) — it isn't a claim that today's required fields are actually
//  null in practice. And `label` is `nullable: true` in `CatalogExportRow`
//  (unlike the AlbumSearchResult schema), so the two schemas aren't even
//  making the same claim about that field.
//
//  The real, verified blocker: `rotation_kill_date` is `format: date` in
//  api.yaml, so the generated type declares it `Date?`. This type
//  deliberately keeps it `String?` (see ``rotationKillDate`` below) so
//  expiry is a timezone-free lexicographic compare against a client-local
//  `"YYYY-MM-DD"` string (``isInRotation(localDay:)``) — converting to
//  `Date` would mean re-deriving that comparison through `Calendar`/
//  `TimeZone` machinery this type was written specifically to avoid. See
//  CLAUDE.md's "Code Generation" section.
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
    /// **not** `CURRENT_DATE`-filtered. `H`/`M`/`L`/`S` are the DJ-facing display
    /// cohorts (see ``rotationCohort``).
    ///
    /// Kept as the raw string rather than the ``RotationBin`` enum as a
    /// **forward-compatibility hedge**, which is the same reason api.yaml types
    /// it as a free string: a bin added server-side ahead of this app would
    /// otherwise collapse to `nil` and make ``isInRotation(asOf:timeZone:)``
    /// report a genuinely in-rotation row as out of it. The invariant this
    /// protects is "**any** non-nil bin means in rotation, per the server's
    /// predicate" — not the specific set of values, which is why the hedge
    /// survives the set being currently closed.
    ///
    /// An earlier version cited `"N"` as a fifth server value and built the
    /// hedge's justification on it. It was never a rotation bin and was removed
    /// from Backend-Service's `freq_enum` in BS#2173 — don't restore the
    /// example; the hedge stands on its own.
    ///
    /// `nil` (including a dirty empty string, normalized on decode) means the
    /// album has no rotation record. Evaluate rotation state with
    /// ``isInRotation(asOf:timeZone:)``, never by reading this directly.
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
        // artwork_url is free-text typed `string | null`. Decode the raw string
        // and build the URL ourselves so a dirty value never throws and fails the
        // WHOLE row — the full-catalog NDJSON clone must not drop a row over one
        // bad URL. An empty string maps to nil; note URL(string:) is lenient and
        // turns most non-empty junk into a (harmless, unloadable) URL rather than
        // nil, which is acceptable here — the goal is row survival, not validation.
        artworkURL = (try c.decodeIfPresent(String.self, forKey: .artworkURL))
            .flatMap { $0.isEmpty ? nil : URL(string: $0) }
        // Raw bin verbatim — preserves any future server value (see the
        // rotationBin doc). null/absent decode to nil; a dirty empty string
        // normalizes to nil too (an empty bin is no rotation), mirroring the
        // artwork_url treatment above.
        rotationBin = (try c.decodeIfPresent(String.self, forKey: .rotationBin))
            .flatMap { $0.isEmpty ? nil : $0 }
        rotationKillDate = try c.decodeIfPresent(String.self, forKey: .rotationKillDate)
    }

    /// The DJ-facing display cohort (`H`/`M`/`L`/`S`) for ``rotationBin``, or
    /// `nil` when there is no bin **or** the raw bin is outside those cohorts —
    /// the case ``rotationBin`` is deliberately typed to survive. A row can be in
    /// rotation (``isInRotation(asOf:timeZone:)``) yet have no display cohort;
    /// use this only for labelling, never for rotation state.
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
    /// client. **Any** non-null bin counts as in rotation, including one outside
    /// the current `H`/`M`/`L`/`S` cohorts; the kill-date comparison is strict (a
    /// record expiring *today* is already out), matching `kill_date > CURRENT_DATE`.
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
    /// string, via the locale-independent ISO-8601 calendar so the result never
    /// drifts with host locale/calendar settings. Uses a value-type format style
    /// (no per-call `DateFormatter` allocation) — the same date-only shape
    /// `JSONCoders` uses for the inverse parse — so it stays cheap if called per row.
    static func localDay(_ now: Date = Date(), timeZone: TimeZone = .current) -> String {
        now.formatted(
            Date.ISO8601FormatStyle(timeZone: timeZone)
                .year().month().day()
                .dateSeparator(.dash)
        )
    }
}
