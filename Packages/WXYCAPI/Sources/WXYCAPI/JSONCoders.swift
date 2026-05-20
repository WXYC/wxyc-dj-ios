//
//  JSONCoders.swift
//  WXYCAPI
//
//  JSONEncoder/JSONDecoder configured for the Backend-Service wire format:
//  snake_case keys (via per-DTO CodingKeys) and ISO-8601 timestamps with
//  optional fractional seconds.
//
//  Created by Jake on 5/14/26.
//  Copyright © 2026 WXYC. All rights reserved.
//

import Foundation

enum JSONCoders {
    static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        // The wire mixes three formats: ISO-8601 with fractional seconds
        // (most timestamps), ISO-8601 without (some columns), and a plain
        // YYYY-MM-DD calendar date (rotation add_date / kill_date). Try the
        // most specific parser first; fall through to the next on failure.
        let dateOnly = Date.ISO8601FormatStyle(timeZone: .gmt)
            .year().month().day()
            .dateSeparator(.dash)
        d.dateDecodingStrategy = .custom { decoder in
            let container = try decoder.singleValueContainer()
            let raw = try container.decode(String.self)
            if let date = try? Date(raw, strategy: Date.ISO8601FormatStyle(includingFractionalSeconds: true)) {
                return date
            }
            if let date = try? Date(raw, strategy: Date.ISO8601FormatStyle()) {
                return date
            }
            if let date = try? Date(raw, strategy: dateOnly) {
                return date
            }
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "Unrecognized date format: \(raw)"
            )
        }
        return d
    }()

    static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        return e
    }()
}
