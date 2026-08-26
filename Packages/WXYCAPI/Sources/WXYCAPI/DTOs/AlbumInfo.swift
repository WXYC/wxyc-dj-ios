//
//  AlbumInfo.swift
//  WXYCAPI
//
//  Decoded shape of GET /library/info?album_id=X.
//  Mirrors the AlbumInfoResponse schema in wxyc-shared/api.yaml — an Album
//  plus denormalized artist/code/format/genre and an optional rotation block.
//
//  Deliberately kept hand-authored, not generated (issue #75). Two reasons,
//  neither of them the required-vs-nullable gap an earlier version of this
//  comment cited (see AlbumSearchResult.swift's doc comment for why that
//  premise doesn't hold in general): (1) the generated `AlbumInfoResponse`
//  is missing `code_artist_number`, `plays`, `on_streaming`, and
//  `artwork_url` outright — they're absent from api.yaml's `Album` /
//  `AlbumInfoResponse` schemas, not merely optional — and `AlbumDetailView.swift`
//  reads all four (`info.artworkURL`, `info.plays`, `info.onStreaming`
//  directly; `codeArtistNumber` feeds `callNumber` below); (2) it needs to
//  try both `label` and `record_label` wire keys (`/library/info` uses the
//  latter, the catalog list endpoint the former), a dual-key fallback a
//  generated `Codable` can't express. (`AlbumInfoResponse` is an OpenAPI
//  `allOf` composite over `Album`, but the generator flattens that into one
//  clean struct without help — not itself a reason to stay hand-authored.)
//  See CLAUDE.md's "Code Generation" section.
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

    /// The nested `rotation` object on `GET /library/info`. **Every field is
    /// optional, deliberately** — `api.yaml`'s nested `rotation` schema declares
    /// no `required` list at all, and the generated `AlbumInfoResponseAllOfRotation`
    /// mirrors that (all four fields optional). The columns being `.notNull()` in
    /// Backend-Service's schema is a database constraint, not an OpenAPI
    /// guarantee, and doesn't license a non-optional decode here.
    ///
    /// Every field is read with `decodeIfPresent`, so a **missing or null** field
    /// can never throw. A non-optional field decoded with plain `decode` would
    /// throw `keyNotFound` out of the enclosing `AlbumInfo` the moment a present
    /// `rotation` object omitted it — failing the entire release-detail load over
    /// one rotation field. That is precisely the failure class issue #93 exists to
    /// close, so closing it for `rotation_bin` alone would just move the defect to
    /// `id` and `add_date`.
    ///
    /// What `decodeIfPresent` alone does **not** buy is total decode safety, and
    /// the gap is worth naming because it reads like more than it is: a *present*
    /// value of the wrong JSON type still throws `typeMismatch`, and still takes
    /// the whole `AlbumInfo` with it. Every field here is therefore read as the
    /// type api.yaml declares and nothing narrower — the two dates stay raw
    /// strings rather than `Date`s — so the only remaining way to throw is a
    /// response that contradicts its own contract, which is not a shape this
    /// hedge is meant to absorb. Note that residue *is* endpoint-wide rather than
    /// rotation-specific: `AlbumInfo`'s own top-level `add_date` and
    /// `artwork_url` do decode to narrowed types, and would throw on a value
    /// those parsers reject.
    ///
    /// Note that `GET /library/info` does not emit `rotation` at all today:
    /// `library.service.getAlbumFromDB` projects no rotation columns and joins no
    /// rotation table, so this decodes to `nil` in practice — the same shape
    /// already documented for `artwork_url` on that identical handler. Rotation
    /// reaches the app through the catalog export (``CatalogRow``) instead. Typed
    /// defensively so the day that projection grows a rotation join isn't the day
    /// release detail starts failing to load.
    public struct Rotation: Codable, Sendable, Hashable {
        public let id: Int?

        /// Raw current-rotation bin verbatim from the wire — **not** the closed
        /// ``RotationBin`` enum. Kept as the raw string as the same
        /// forward-compatibility hedge ``CatalogRow/rotationBin`` documents: a
        /// bin added server-side ahead of this app must decode rather than throw
        /// out of the whole `AlbumInfo` (issue #93). Read ``rotationCohort`` for
        /// display; this is the unnarrowed wire value.
        ///
        /// `nil` (including a dirty empty string, normalized on decode) means the
        /// record carries no rotation assignment — the same treatment
        /// ``CatalogRow/rotationBin`` gives the same underlying column, so the
        /// online and cloned paths can't disagree about what `""` means. This
        /// feeds the in-rotation predicate, so an empty string left verbatim
        /// would read as in-rotation.
        ///
        /// Don't read this directly to decide rotation state — a bin can be set
        /// on a record whose ``killDate`` has already passed. Call
        /// ``isInRotation(asOf:timeZone:)``, the same caution
        /// ``CatalogRow/rotationBin`` carries.
        public let rotationBin: String?

        /// Date this rotation record began, as the raw `"YYYY-MM-DD"` the wire
        /// carries. Raw for the same reason as ``killDate`` below (uniform
        /// treatment of the pair, and one less thing that can throw); render it
        /// with ``WXYCDateFormatting/dateOnly(fromISOString:locale:)``.
        public let addDate: String?

        /// Date this rotation record expires, as the raw `"YYYY-MM-DD"` the wire
        /// carries — **not** a decoded `Date`.
        ///
        /// The two row types deliberately **stop agreeing here**, and the
        /// asymmetry is the point rather than an oversight:
        /// ``CatalogRow/rotationKillDate`` narrows at decode into a
        /// ``RotationKillDate``, because it is a real, shipping projection whose
        /// column shape is known; this one stays a `String?` and converts at the
        /// call in ``isInRotation(asOf:timeZone:)``. Both reach the *same*
        /// predicate with the same ``RotationKillDate``, so they cannot answer
        /// differently — which is the invariant that actually matters, and the
        /// one the issue-#95 parity matrix pins.
        ///
        /// Holding the string is worth the asymmetry because this whole type is
        /// a hedge against a `/library/info` rotation projection that does not
        /// exist yet. Every field here is `decodeIfPresent` so that a shape we
        /// guessed wrong degrades instead of failing the whole `AlbumInfo`, and
        /// a `String?` is the shape with nothing left to get wrong: whatever
        /// arrives survives decode intact and is judged once, at the call.
        ///
        /// A decoded `Date` would be strictly worse for the same reason it is
        /// wrong on ``CatalogRow``. A `Date` is an *instant*, not a calendar
        /// day, so recovering the wire day from one means picking a zone to
        /// render it back through — and any choice is wrong for some input.
        /// (``JSONCoders`` no longer parses a bare `"YYYY-MM-DD"` into one at
        /// all; issue #79 retired that branch precisely so this can't be done by
        /// accident.)
        public let killDate: String?

        enum CodingKeys: String, CodingKey {
            case id
            case rotationBin = "rotation_bin"
            case addDate = "add_date"
            case killDate = "kill_date"
        }

        /// Decodes every field with `decodeIfPresent` (see the type doc — a plain
        /// `decode` on any one of them would fail the whole `AlbumInfo`), and
        /// normalizes a dirty empty `rotation_bin` to `nil`. `encode(to:)` stays
        /// synthesized, as on ``CatalogRow``, whose decoder this mirrors.
        ///
        /// Both dates are read as raw strings rather than `Date`s (see
        /// ``killDate``), which also removes the last way a *contract-legal*
        /// rotation object could throw: with no date parsing left, only a value
        /// of the wrong JSON type can fail, and that is a contract violation
        /// rather than a shape this hedge is meant to absorb.
        public init(from decoder: any Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            id = try c.decodeIfPresent(Int.self, forKey: .id)
            rotationBin = (try c.decodeIfPresent(String.self, forKey: .rotationBin))
                .flatMap { $0.isEmpty ? nil : $0 }
            // `addDate` normalizes a dirty empty string to nil (it is decorative,
            // and nil simply omits the line). `killDate` deliberately does NOT:
            // for the bin, "empty" and nil both mean "no assignment", which is
            // the safe direction, but for a kill date nil means *no expiry* — so
            // folding `""` into it would resurrect the forever-in-rotation bug
            // this type guards against. An empty kill date instead reaches
            // ``RotationPredicate/isInRotation(bin:killDate:today:)`` intact and
            // fails closed there, with the other unreadable values.
            addDate = (try c.decodeIfPresent(String.self, forKey: .addDate))
                .flatMap { $0.isEmpty ? nil : $0 }
            killDate = try c.decodeIfPresent(String.self, forKey: .killDate)
        }

        /// The DJ-facing display cohort (`H`/`M`/`L`/`S`) for ``rotationBin``, or
        /// `nil` when the bin is absent or outside those cohorts — both cases
        /// ``rotationBin`` is deliberately typed to survive. Mirrors
        /// ``CatalogRow/rotationCohort``; use this only for labelling.
        public var rotationCohort: RotationBin? {
            rotationBin.flatMap(RotationBin.init(rawValue:))
        }

        /// Whether this record is in rotation as of `now` in `timeZone` (defaults:
        /// the device's current clock). Deliberately the **same** predicate
        /// ``CatalogRow/isInRotation(asOf:timeZone:)`` applies — a bin is set, and
        /// either there's no kill date or it is strictly after today, matching the
        /// server's `rotation_bin != null && (kill_date == null || kill_date >
        /// CURRENT_DATE)`. A record expiring *today* is already out.
        ///
        /// Sharing one rule is the whole point: rotation reaches the DJ through
        /// this type when `/library/info` answers and through ``CatalogRow`` when
        /// the on-device clone does, and the two must not give one album two
        /// answers. Gating a rotation UI on `rotationBin != nil` instead would
        /// render an expired record as in-rotation online while the clone
        /// correctly hid it.
        public func isInRotation(asOf now: Date = Date(), timeZone: TimeZone = .current) -> Bool {
            isInRotation(today: CalendarDate(now, in: timeZone))
        }

        /// Pure core of ``isInRotation(asOf:timeZone:)``. `today` is the
        /// client's local calendar day; `internal` so callers go through the
        /// public overload, which derives it.
        ///
        /// The rule is still ``RotationPredicate``'s, shared with ``CatalogRow``
        /// — but this reaches it through the **raw-string** overload, because
        /// ``killDate`` is deliberately held as the un-narrowed wire value
        /// (see its doc comment) where ``CatalogRow/rotationKillDate`` decodes
        /// to a ``CalendarDate``. That overload delegates to the same
        /// comparison, so the two paths still cannot answer differently for the
        /// same album; what it adds is the parse and the fail-closed decision an
        /// unparsed value needs. The asymmetry is the point rather than a wart:
        /// the export's column is a Postgres `date` via `::text` and can be
        /// typed, while this block's shape is unknown enough that api.yaml no
        /// longer declares it at all.
        func isInRotation(today: CalendarDate) -> Bool {
            RotationPredicate.isInRotation(bin: rotationBin, killDate: RotationKillDate(wireValue: killDate), today: today)
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
