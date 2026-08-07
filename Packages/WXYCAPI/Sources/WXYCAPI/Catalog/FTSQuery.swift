//
//  FTSQuery.swift
//  WXYCAPI
//
//  Pure builder that turns raw DJ-typed search text into a safe FTS5 MATCH
//  expression for the offline catalog index (issue #58). Each whitespace token
//  becomes a quoted prefix term so partial input matches as you type, and any
//  embedded double quote is doubled so user punctuation can never inject MATCH
//  syntax.
//
//  Created by Jake on 06/28/26.
//  Copyright © 2026 WXYC. All rights reserved.
//

import Foundation

/// Safe FTS5 `MATCH` expression builder for the on-device catalog index.
public enum FTSQuery {
    /// Build a safe FTS5 `MATCH` string from raw user input, or `nil` for an
    /// empty/whitespace-only query.
    ///
    /// Splits on whitespace and wraps each token as a **quoted prefix** term:
    /// `"foo"` → `"foo"*`, `"bar baz"` → `"bar"* "baz"*` (the space-separated
    /// terms are implicitly AND-ed by FTS5). Wrapping every token in double
    /// quotes neutralizes FTS5 operators (`AND`, `OR`, `NOT`, `*`, `(`, `:`),
    /// and any double quote *inside* a token is escaped by doubling it (`"` →
    /// `""`) — the FTS5 string-escaping rule — so punctuation is always treated
    /// as literal text rather than query syntax.
    public static func match(for raw: String) -> String? {
        let tokens = raw.split(whereSeparator: \.isWhitespace)
        guard !tokens.isEmpty else { return nil }
        return tokens
            .map { token in
                let escaped = token.replacingOccurrences(of: "\"", with: "\"\"")
                return "\"\(escaped)\"*"
            }
            .joined(separator: " ")
    }
}
