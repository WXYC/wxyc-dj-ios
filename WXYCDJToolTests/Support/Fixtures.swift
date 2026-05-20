//
//  Fixtures.swift
//  WXYCDJToolTests
//
//  WXYC-representative wire-format strings for app-target tests. Mirrors a
//  subset of Packages/WXYCAPI/Tests/WXYCAPITests/Support/Fixtures.swift —
//  duplicated for the same reason as StubRequestSession.
//
//  Created by Jake on 5/19/26.
//  Copyright © 2026 WXYC. All rights reserved.
//

import Foundation

enum Fixtures {
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
            },
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
          ]
        }
        """

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
