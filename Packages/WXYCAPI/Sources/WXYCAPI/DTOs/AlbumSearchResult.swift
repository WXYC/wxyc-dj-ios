//
//  AlbumSearchResult.swift
//  WXYCAPI
//
//  Decoded shape of a row returned by Backend-Service GET /library/.
//  Mirrors the AlbumSearchResult schema in wxyc-shared/api.yaml.
//
//  Deliberately kept hand-authored, not generated (issue #75). NOT because
//  `code_letters`/`code_number`/`code_artist_number`/`format_name`/
//  `genre_name`/`label` carry NULL for V/A compilations or unfiled adds, as
//  an earlier version of this comment claimed — that's false. Those five
//  code/format/genre columns are `.notNull()` in Backend-Service's schema
//  (shared/database/src/schema.ts) and `library_artist_view` (the source
//  `GET /library/` reads) reaches every one of them through an INNER JOIN,
//  so a row missing one is simply absent from the result set, never present
//  with a null in that field. `label` (~schema.ts:566) is the one column in
//  that family that's actually nullable — and it's the one field the
//  generated type ALSO declares non-optional-but-required, matching
//  api.yaml's schema exactly (no gap there either, since
//  library-search.service.ts coalesces a null `library.label` to `""`
//  before it ever reaches the wire).
//
//  The real reasons: (1) the generated `matchedVia` is `[TrackMatchHint]?`
//  (optional — api.yaml doesn't mark it required), where this app's
//  contract is a non-optional `[TrackMatchHint]` that callers rely on
//  reading via `.isEmpty` without unwrapping (see the property doc below);
//  (2) the generated `RotationBin`'s cases are spelled `.h`/`.m`/`.l`/`.s`
//  (+ `.unknownDefaultOpenApi`), not this app's `.heavy`/`.medium`/`.light`/
//  `.single` below — `SearchResultRow.swift` already switches exhaustively
//  over the latter, so adopting the generated enum would ripple a rename
//  through the UI, not just this file. `matchedVia`'s element type,
//  `TrackMatchHint`, IS generated (see TrackMatchHint.swift) — that schema
//  has neither gap. See CLAUDE.md's "Code Generation" section.
//
//  Created by Jake on 5/14/26.
//  Copyright © 2026 WXYC. All rights reserved.
//

import Foundation

/// Wraps a `Decodable` element so a failed per-element decode inside an
/// array (unparseable JSON shape, a required field the wire omitted, etc.)
/// drops just that element instead of failing the whole array decode. Used
/// by `AlbumSearchResult.matchedVia` (see the doc comment on its
/// `init(from:)`) to isolate one malformed `TrackMatchHint` from the rest of
/// a search-result row.
struct FailableDecodable<Base: Decodable>: Decodable {
    let value: Base?

    init(from decoder: any Decoder) throws {
        value = try? Base(from: decoder)
    }
}

// Codable, not decode-only: besides decoding from Backend-Service
// (`GET /library/` and, per issue #19, the bulk `GET /library/catalog`),
// rows are encoded back out to persist the on-device catalog clone's local
// store. Swift synthesizes `encode(to:)` from the CodingKeys; the custom
// `init(from:)` below stays for the tolerant snake_case decode.
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
    /// Populated when a track-title match drove this row into results
    /// (catalog-track-search Track 1 CTA fallback or Track 2 LML proxy).
    /// Empty on a normal artist or album hit.
    public let matchedVia: [TrackMatchHint]

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
        case matchedVia = "matched_via"
    }

    /// Memberwise initializer. Defined explicitly because the custom
    /// `init(from:)` in the type body suppresses the synthesized one — needed
    /// by `CatalogRow.detailFallback`, which builds a header-render stand-in
    /// from a cloned catalog row (issue #19).
    public init(
        id: Int,
        addDate: Date? = nil,
        albumTitle: String,
        artistName: String,
        codeLetters: String? = nil,
        codeNumber: Int? = nil,
        codeArtistNumber: Int? = nil,
        formatName: String? = nil,
        genreName: String? = nil,
        label: String? = nil,
        labelId: Int? = nil,
        rotationBin: RotationBin? = nil,
        rotationId: Int? = nil,
        plays: Int? = nil,
        onStreaming: Bool? = nil,
        albumArtist: String? = nil,
        artworkURL: URL? = nil,
        matchedVia: [TrackMatchHint] = []
    ) {
        self.id = id
        self.addDate = addDate
        self.albumTitle = albumTitle
        self.artistName = artistName
        self.codeLetters = codeLetters
        self.codeNumber = codeNumber
        self.codeArtistNumber = codeArtistNumber
        self.formatName = formatName
        self.genreName = genreName
        self.label = label
        self.labelId = labelId
        self.rotationBin = rotationBin
        self.rotationId = rotationId
        self.plays = plays
        self.onStreaming = onStreaming
        self.albumArtist = albumArtist
        self.artworkURL = artworkURL
        self.matchedVia = matchedVia
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
        // Per-element, not `decodeIfPresent([TrackMatchHint].self, ...)`: LML
        // is a separately deployed service, and Backend-Service passes
        // `matched_via` through unvalidated (library-search.service.ts), so
        // one malformed hint on the wire must not fail this whole row (and,
        // by extension, the whole `[AlbumSearchResult]` array
        // `APIClient.searchLibrary` decodes all-or-nothing). TrackMatchHint
        // is the generated WXYCAPIModels type: `source` is non-optional and
        // its `init(from:)` is synthesized, so a hint with `source` absent
        // or `source: null` throws instead of tolerating it the way the old
        // hand-rolled `try?` decode did. `FailableDecodable` isolates each
        // element's decode failure instead of letting it propagate through
        // the array decode -- strictly more tolerant than main's old
        // `try? c.decode(...)`-per-field behavior, which only tolerated an
        // unrecognized `source` value, not an absent/null one.
        matchedVia = (try c.decodeIfPresent([FailableDecodable<TrackMatchHint>].self, forKey: .matchedVia))?
            .compactMap(\.value) ?? []
    }

    /// Shelf call number in the form "<codeLetters> <codeArtistNumber>/<codeNumber>"
    /// (e.g. "AU 3/2"). Any leg that's missing on the wire is dropped so we
    /// never render an Optional() literal.
    public var callNumber: String {
        Self.formatCallNumber(letters: codeLetters, artistNumber: codeArtistNumber, releaseNumber: codeNumber)
    }

    /// Build an `AlbumSearchResult` that stands in for a row not yet fetched,
    /// so `AlbumDetailView` (whose `fallback` is typed `AlbumSearchResult?`)
    /// can render its header immediately from data already in hand.
    ///
    /// This is the one place that decides what a stand-in **drops**, and it is
    /// shared by every `detailFallback` bridge (``CatalogRow/detailFallback``
    /// for the Spotlight deep link, ``BinEntry/detailFallback`` for Bin →
    /// Detail) so the decision can't drift between them. Callers pass only the
    /// twelve fields a stand-in can ever carry; the six below are fixed here:
    ///
    /// - `rotationBin` / `rotationId` are **always** `nil`. `RotationBin` is an
    ///   `H`/`M`/`L`/`S` cohort enum and cannot faithfully represent a raw
    ///   catalog bin — it would collapse a valid `"N"` (still in rotation per
    ///   the server predicate) to `nil` and read as *out* of rotation. Rotation
    ///   for a cloned row comes from `CatalogRow.isInRotation(asOf:timeZone:)` /
    ///   `rotationCohort`; the bin projection carries no rotation data at all.
    /// - `addDate`, `labelId`, `albumArtist`, `matchedVia` exist only to
    ///   decorate a real search response and have no meaning on a stand-in.
    ///
    /// Lossless **for the header render**, not a full round-trip: the detail
    /// view's authoritative shelf and rotation data still come from
    /// `/library/info`.
    static func headerStandIn(
        id: Int,
        albumTitle: String,
        artistName: String,
        codeLetters: String?,
        codeNumber: Int?,
        codeArtistNumber: Int?,
        formatName: String?,
        genreName: String?,
        label: String?,
        plays: Int? = nil,
        onStreaming: Bool? = nil,
        artworkURL: URL? = nil
    ) -> AlbumSearchResult {
        AlbumSearchResult(
            id: id,
            addDate: nil,
            albumTitle: albumTitle,
            artistName: artistName,
            codeLetters: codeLetters,
            codeNumber: codeNumber,
            codeArtistNumber: codeArtistNumber,
            formatName: formatName,
            genreName: genreName,
            label: label,
            labelId: nil,
            rotationBin: nil,
            rotationId: nil,
            plays: plays,
            onStreaming: onStreaming,
            albumArtist: nil,
            artworkURL: artworkURL,
            matchedVia: []
        )
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
