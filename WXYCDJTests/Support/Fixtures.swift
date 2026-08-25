//
//  Fixtures.swift
//  WXYCDJTests
//
//  WXYC-representative wire-format strings for app-target tests. Mirrors a
//  subset of Packages/WXYCAPI/Tests/WXYCAPITests/Support/Fixtures.swift —
//  duplicated for the same reason as StubRequestSession.
//
//  Created by Jake on 5/19/26.
//  Copyright © 2026 WXYC. All rights reserved.
//

import Foundation
@testable import WXYCAPI

enum Fixtures {
    /// Single-result wire body for GET /library/. Used by SearchViewModel tests.
    static let juanaMolinaSearchResultsJSON = """
        [
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
        ]
        """

    /// The two `binResponseJSON` rows, decoded, in wire order (Pratt, then
    /// Molina) — so a test can model a previously-persisted snapshot without
    /// re-spelling the projection. Mirrors `WXYCAPITests`' helper of the same
    /// name, like the rest of this file.
    static func binEntries() throws -> [BinEntry] {
        try JSONCoders.decoder.decode([BinEntry].self, from: Data(binResponseJSON.utf8))
    }

    /// The Juana Molina / DOGA row from ``binEntries()``. Mirrors `WXYCAPITests`'
    /// helper of the same name, like the rest of this file — a suite that wants
    /// one representative bin row decodes it from the shared wire body instead
    /// of re-spelling the projection as a literal that drifts on the next
    /// `/djs/bin` field addition.
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

    /// Wire body for POST /djs/bin (201) — the raw inserted `bins` row the
    /// server returns. The client doesn't decode it; tests enqueue it only to
    /// satisfy the response side after exercising addToBin.
    static let addToBinResponseJSON = """
        {
          "id": 7,
          "dj_id": "yzT4kQ2mNc8fVb1L",
          "album_id": 100,
          "track_title": null
        }
        """

    /// Wire body for GET /djs/bin — a bare array of denormalized library rows
    /// (api.yaml `BinLibraryDetails`), in the arbitrary order an un-ORDER-BY'd
    /// server projection can hand back.
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

    /// One catalog row as compact, single-line NDJSON — the exact
    /// `GET /library/catalog` wire shape (one `CatalogExportRow` per line).
    /// Mirrors `WXYCAPITests/Support/Fixtures.catalogNDJSON`'s first row
    /// (Juana Molina / DOGA); duplicated for the same reason as the rest of
    /// this file.
    static let catalogNDJSON =
        #"{"id":100,"artist_name":"Juana Molina","album_title":"DOGA","code_letters":"MOL","code_number":12,"code_artist_number":1,"label":"Sonamos","genre_name":"Rock","format_name":"CD","on_streaming":true,"plays":34,"artwork_url":"https://img.discogs.com/doga.jpg","rotation_bin":"H","rotation_kill_date":"2026-07-01"}"#

    /// JWT with payload {"sub":"42","email":"juana@wxyc.org","role":"dj","exp": <Date>}.
    /// Signature is a placeholder; the client doesn't verify it.
    static func jwt(expiresIn seconds: TimeInterval = 600) -> String {
        let exp = Int(Date().addingTimeInterval(seconds).timeIntervalSince1970)
        let header = "eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9"
        let payloadJSON = #"{"sub":"42","email":"juana@wxyc.org","role":"dj","exp":\#(exp)}"#
        let payload = Data(payloadJSON.utf8).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
        return "\(header).\(payload).sig"
    }
}
