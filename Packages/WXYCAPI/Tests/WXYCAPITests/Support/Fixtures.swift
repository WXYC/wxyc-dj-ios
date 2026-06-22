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

enum Fixtures {
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

    static let djBinResponseJSON = """
        {
          "dj_id": 42,
          "entries": [
            {
              "id": 1,
              "dj_id": 42,
              "album_id": 100,
              "added_at": "2025-11-01T22:15:00.000Z",
              "album_title": "DOGA",
              "artist_name": "Juana Molina",
              "code_letters": "MOL",
              "code_number": 12
            }
          ]
        }
        """

    static let binEntryJSON = """
        {
          "id": 2,
          "dj_id": 42,
          "album_id": 200,
          "added_at": "2025-11-02T12:30:00.000Z",
          "album_title": "On Your Own Love Again",
          "artist_name": "Jessica Pratt",
          "code_letters": "PRA",
          "code_number": 5
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
