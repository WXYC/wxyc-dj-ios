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
//  The blocker this comment used to name is CLOSED (issue #79).
//  `rotation_kill_date` is `format: date`, which generated as `Date?` — an
//  instant, so recovering the wire day from one means choosing a time zone —
//  and this type kept it `String?` so expiry stayed a timezone-free compare.
//  Since the pin moved to api.yaml 1.47.0 the generated property is
//  `CalendarDate?`, which stores `(year, month, day)` and orders by that
//  triple without consulting `Calendar`/`TimeZone`: the exact property the
//  string was standing in for, so this type now uses it too.
//
//  What still blocks generation is decode tolerance a synthesized `Codable`
//  cannot express — `artworkURL` is built from a raw `String` with empty→nil
//  and `URL(string:)` applied by hand, and `rotationBin` normalizes a dirty
//  `""` to nil — plus the affordances (`callNumber`, `isInRotation`,
//  `detailFallback`) callers reach for. Five fields are also non-optional on
//  the generated type where they're optional here. See CLAUDE.md's "Code
//  Generation" section.
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

    /// When the current rotation record expires — as ``RotationKillDate``'s
    /// **three** states, not a `CalendarDate?`'s two. Absent is `.noExpiry`; a
    /// readable day is `.expires`; anything else is `.unreadable`, retained
    /// verbatim.
    ///
    /// The server emits `"YYYY-MM-DD"` from a deliberate `::text` cast over a
    /// Postgres `date` column: a stable calendar day, never a parser-dependent
    /// instant. ``CalendarDate`` is the type-level statement of that — it holds
    /// `(year, month, day)` and orders by the triple, so expiry stays the
    /// timezone-free compare it has always been, now without the padded-string
    /// precondition that used to be enforced only by a doc comment.
    ///
    /// **This field decodes as tolerantly as ``artworkURL`` and ``rotationBin``
    /// beside it**, and that uniformity is deliberate. Typing it `CalendarDate?`
    /// and letting the strict generated decoder throw was the obvious reading of
    /// issue #79, and it is the wrong trade here: ``APIClient/decodeNDJSON``
    /// fails the **whole fetch** on any throwing line, so one malformed kill
    /// date would cost the entire on-device clone refresh rather than one
    /// album's badge. Such a value cannot come from a `date` column via `::text`
    /// — it would be a Backend-Service defect — but "cannot happen" is a
    /// property of today's server, and the cost of being wrong about it is the
    /// whole clone.
    ///
    /// Tolerating it is **not** the same as ignoring it: an unreadable value
    /// fails **closed** at ``RotationPredicate/isInRotation(bin:killDate:today:)``
    /// (treated as expired), which is why the third case exists rather than
    /// folding into the `nil` that means "no expiry". See ``RotationKillDate``.
    public let rotationKillDate: RotationKillDate

    /// Whether the digital archive (WXYC/Backend-Service#2320) has at least one
    /// asset bound to this album — the badge the archive player client uses to
    /// decide whether to offer playback before calling
    /// `GET /digital-archive/albums/{id}/playback`. Absent on the wire decodes
    /// to `false`, the same per-field tolerance ``artworkURL``/``rotationBin``
    /// get: a Backend that hasn't deployed #2320 yet omits the key entirely,
    /// and a pre-existing clone on disk (encoded before this field existed)
    /// must still decode. The badge means "some audio available," not "the
    /// whole album" — a stale badge (the clone refreshes on launch/foreground)
    /// can only over- or under-badge; the endpoint's 200/404 is what actually
    /// gates playback.
    public let hasDigitalAudio: Bool

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
        rotationKillDate: CalendarDate?,
        hasDigitalAudio: Bool = false
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
        self.rotationKillDate = rotationKillDate.map(RotationKillDate.expires) ?? .noExpiry
        self.hasDigitalAudio = hasDigitalAudio
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
        case hasDigitalAudio = "has_digital_audio"
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
        // Decoded as a raw string and narrowed here rather than as a
        // `CalendarDate` directly: a strict decode would THROW on an unreadable
        // value, and `APIClient.decodeNDJSON` fails the whole fetch on any
        // throwing line, so one dirty kill date would cost the entire clone
        // refresh instead of one album's badge. Narrowing keeps the tolerance
        // this decoder applies to `artwork_url` and `rotation_bin` above while
        // still typing the comparison -- see `RotationKillDate`.
        rotationKillDate = RotationKillDate(
            wireValue: try c.decodeIfPresent(String.self, forKey: .rotationKillDate)
        )
        // Absent -> false: a Backend that hasn't deployed #2320 yet omits the
        // key entirely, and a pre-existing on-disk clone (encoded before this
        // field existed) must still decode rather than losing the whole row.
        hasDigitalAudio = try c.decodeIfPresent(Bool.self, forKey: .hasDigitalAudio) ?? false
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
    /// The rule itself lives in ``RotationPredicate`` so this type and
    /// ``AlbumInfo/Rotation`` cannot answer differently for the same album.
    public func isInRotation(asOf now: Date = Date(), timeZone: TimeZone = .current) -> Bool {
        isInRotation(today: CalendarDate(now, in: timeZone))
    }

    /// Pure core of ``isInRotation(asOf:timeZone:)``. `today` is the client's
    /// local calendar day, which ``CalendarDate/init(_:in:)`` derives from an
    /// instant and a zone.
    ///
    /// This used to take a zero-padded `"YYYY-MM-DD"` **string**, with a doc
    /// comment insisting on that shape because the lexicographic compare was
    /// only equivalent to a chronological one for the fixed-width form, and an
    /// `internal` visibility to stop an outside caller passing something else.
    /// `CalendarDate` makes the precondition unrepresentable instead of
    /// restating it, so this stays `internal` purely to route callers through
    /// the public overload — not because a malformed value is still possible.
    /// Batch callers build the day once and reuse it across rows.
    func isInRotation(today: CalendarDate) -> Bool {
        RotationPredicate.isInRotation(bin: rotationBin, killDate: rotationKillDate, today: today)
    }
}
