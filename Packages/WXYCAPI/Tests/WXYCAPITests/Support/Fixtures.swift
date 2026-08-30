//
//  Fixtures.swift
//  WXYCAPITests
//
//  WXYC-representative test data. Pulled from
//  wxyc-shared/src/test-utils/wxyc-example-data.json — Juana Molina,
//  Jessica Pratt, Chuquimamani-Condori. No mainstream substitutes per the
//  org-level CLAUDE.md rule.
//
//  Created by Jake on 5/14/26.
//  Copyright © 2026 WXYC. All rights reserved.
//

import Foundation
@testable import WXYCAPI

enum Fixtures {
    /// The two WXYC-representative export rows (Juana Molina id 100, Jessica
    /// Pratt id 200) decoded from the ``catalogNDJSON`` wire fixture. Shared by
    /// every suite that needs `[CatalogRow]` so the decode lives in one place.
    static func catalogRows() throws -> [CatalogRow] {
        try catalogNDJSON
            .split(separator: "\n")
            .map { try JSONCoders.decoder.decode(CatalogRow.self, from: Data($0.utf8)) }
    }

    static let juanaMolinaSearchResult = """
        {
          "id": 100,
          "add_date": "2025-10-12T00:00:00.000Z",
          "album_title": "DOGA",
          "artist_name": "Juana Molina",
          "code_letters": "MOL",
          "code_number": 12,
          "code_artist_number": 1,
          "format_name": "CD",
          "genre_name": "Rock",
          "label": "Sonamos",
          "rotation_bin": "H"
        }
        """

    /// A full 14-field GET /library/catalog export row (BS#1468) — the shape
    /// CatalogRow decodes. Distinct from juanaMolinaSearchResult: raw rotation
    /// (rotation_bin + rotation_kill_date), no search decoration. The kill_date
    /// is in the future, so the row reads as in rotation.
    static let juanaMolinaCatalogRow = """
        {
          "id": 100,
          "artist_name": "Juana Molina",
          "album_title": "DOGA",
          "code_letters": "MOL",
          "code_number": 12,
          "code_artist_number": 1,
          "label": "Sonamos",
          "genre_name": "Rock",
          "format_name": "CD",
          "on_streaming": true,
          "plays": 34,
          "artwork_url": "https://img.discogs.com/doga.jpg",
          "rotation_bin": "H",
          "rotation_kill_date": "2026-07-01"
        }
        """

    /// Two catalog rows as compact, single-line NDJSON — the exact
    /// `GET /library/catalog` wire shape (one `CatalogExportRow` per line,
    /// `\n`-joined, no trailing newline; see `serializeCatalogNdjson`).
    /// Deliberately NOT built from `juanaMolinaCatalogRow`, which is
    /// pretty-printed across lines and would be invalid as an NDJSON record.
    /// Row 1 (Juana Molina) carries a future kill date + every field populated;
    /// row 2 (Jessica Pratt) nulls the optionals so the lenient decode path is
    /// exercised too.
    static let catalogNDJSON = [
        #"{"id":100,"artist_name":"Juana Molina","album_title":"DOGA","code_letters":"MOL","code_number":12,"code_artist_number":1,"label":"Sonamos","genre_name":"Rock","format_name":"CD","on_streaming":true,"plays":34,"artwork_url":"https://img.discogs.com/doga.jpg","rotation_bin":"H","rotation_kill_date":"2026-07-01"}"#,
        #"{"id":200,"artist_name":"Jessica Pratt","album_title":"On Your Own Love Again","code_letters":"PRA","code_number":5,"code_artist_number":1,"label":"Drag City","genre_name":"Rock","format_name":"LP","on_streaming":false,"plays":12,"artwork_url":null,"rotation_bin":null,"rotation_kill_date":null}"#,
    ].joined(separator: "\n")

    static let albumInfoJSON = """
        {
          "id": 100,
          "artist_id": 555,
          "album_title": "DOGA",
          "code_number": 12,
          "code_letters": "MOL",
          "artist_name": "Juana Molina",
          "format_name": "CD",
          "genre_name": "Rock",
          "label": "Sonamos",
          "add_date": "2025-10-12T00:00:00.000Z",
          "rotation": {
            "id": 9,
            "rotation_bin": "H",
            "add_date": "2025-10-15",
            "kill_date": null
          }
        }
        """

    /// Wire body for GET /djs/bin — a bare array of the denormalized library
    /// join `djs.service.getBinFromDB` projects (api.yaml `BinLibraryDetails`).
    /// No envelope, no `bins.id` / `dj_id` / added-at: this is the shape the
    /// server actually emits, and the shape dj-site decodes.
    static let binResponseJSON = """
        [
          {
            "album_id": 200,
            "album_title": "On Your Own Love Again",
            "artist_name": "Jessica Pratt",
            "alphabetical_name": "Pratt, Jessica",
            "label": "Drag City",
            "code_letters": "PRA",
            "code_artist_number": 1,
            "code_number": 5,
            "format_name": "LP",
            "genre_name": "Rock",
            "legacy_release_id": 88221
          },
          {
            "album_id": 100,
            "album_title": "DOGA",
            "artist_name": "Juana Molina",
            "alphabetical_name": "Molina, Juana",
            "label": "Sonamos",
            "code_letters": "MOL",
            "code_artist_number": 1,
            "code_number": 12,
            "format_name": "CD",
            "genre_name": "Rock",
            "legacy_release_id": 55123
          }
        ]
        """

    /// The two `binResponseJSON` rows, decoded. Shared by every suite that
    /// needs `[BinEntry]` so the bin projection is spelled once — the same
    /// arrangement as ``catalogRows()``. Preserves wire order (Pratt, then
    /// Molina), which is what makes it useful for testing the shelf sort.
    static func binEntries() throws -> [BinEntry] {
        try JSONCoders.decoder.decode([BinEntry].self, from: Data(binResponseJSON.utf8))
    }

    /// The Juana Molina / DOGA row from ``binEntries()``, named so a suite that
    /// wants one representative bin row doesn't re-spell the projection as a
    /// literal — a literal drifts silently the next time `/djs/bin` gains a
    /// field (wxyc-shared#344 adds `alphabetical_name` to the schema), whereas
    /// this decodes from the same wire body every other bin test uses.
    static func dogaBinEntry() throws -> BinEntry {
        guard let row = try binEntries().first(where: { $0.albumId == 100 }) else {
            throw FixtureError.missingRow("bin row album_id 100 (Juana Molina / DOGA)")
        }
        return row
    }

    enum FixtureError: Error, CustomStringConvertible {
        case missingRow(String)

        var description: String {
            switch self {
            case let .missingRow(what): "Fixtures is missing \(what)"
            }
        }
    }

    /// Wire body for POST /djs/bin (201). The server returns the raw inserted
    /// `bins` row — NOT a bin entry — so the client deliberately doesn't decode
    /// it. Kept so the addToBin test proves that body can't fail the call.
    static let addToBinResponseJSON = """
        {
          "id": 7,
          "dj_id": "yzT4kQ2mNc8fVb1L",
          "album_id": 200,
          "track_title": null
        }
        """

    /// Wire body for `GET /digital-archive/albums/{id}/playback` (#417/#422) —
    /// one track, two renditions, so both the codec enum and the per-track
    /// `provenance` field (not manifest-level — see the schema doc comment) get
    /// exercised. `expires_at` carries fractional seconds, mirroring the "with
    /// or without fractions" tolerance `JSONCoders` already handles.
    static let digitalArchivePlaybackJSON = """
        {
          "library_id": 100,
          "expires_at": "2026-08-29T21:00:00.000Z",
          "tracks": [
            {
              "file_id": 9001,
              "provenance": "rotation_upload",
              "disc_number": 1,
              "track_number": 1,
              "title": "la paradoja",
              "duration_secs": 245.5,
              "content_hash": "abc123",
              "renditions": [
                { "codec": "mp3", "bitrate_kbps": 320, "url": "https://cdn.example.org/doga/01.mp3" },
                { "codec": "flac", "url": "https://cdn.example.org/doga/01.flac" }
              ]
            }
          ]
        }
        """

    /// JWT with payload {"sub":"42","email":"juana@wxyc.org","role":"dj","exp": <Date>}
    /// Signature is a placeholder ("sig"); the client does not verify it.
    static func jwt(expiresIn seconds: TimeInterval = 600) -> String {
        let exp = Int(Date().addingTimeInterval(seconds).timeIntervalSince1970)
        let header = "eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9" // {"alg":"HS256","typ":"JWT"}
        let payloadJSON = #"{"sub":"42","email":"juana@wxyc.org","role":"dj","exp":\#(exp)}"#
        let payloadData = Data(payloadJSON.utf8)
        let payload = payloadData.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
        return "\(header).\(payload).sig"
    }
}
