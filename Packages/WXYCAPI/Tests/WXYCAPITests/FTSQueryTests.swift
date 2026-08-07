//
//  FTSQueryTests.swift
//  WXYCAPITests
//
//  Pins FTSQuery.match: empty/whitespace input yields nil; each whitespace
//  token becomes a quoted prefix term; embedded double quotes are doubled so
//  punctuation can never inject FTS5 MATCH syntax (issue #58).
//
//  Created by Jake on 06/28/26.
//  Copyright © 2026 WXYC. All rights reserved.
//

import Foundation
import Testing
@testable import WXYCAPI

@Suite("FTSQuery")
struct FTSQueryTests {
    @Test func emptyInputYieldsNil() {
        #expect(FTSQuery.match(for: "") == nil)
    }

    @Test func whitespaceOnlyInputYieldsNil() {
        #expect(FTSQuery.match(for: "   ") == nil)
        #expect(FTSQuery.match(for: "\n\t  ") == nil)
    }

    @Test func singleTokenBecomesQuotedPrefix() {
        #expect(FTSQuery.match(for: "juana") == "\"juana\"*")
    }

    @Test func multipleTokensEachBecomeQuotedPrefix() {
        #expect(FTSQuery.match(for: "jessica pratt") == "\"jessica\"* \"pratt\"*")
    }

    @Test func collapsesSurroundingAndInteriorWhitespace() {
        #expect(FTSQuery.match(for: "  juana   molina  ") == "\"juana\"* \"molina\"*")
    }

    @Test func embeddedDoubleQuotesAreDoubled() {
        // Token `a"b` → escaped `a""b` → wrapped `"a""b"*`. Doubling the inner
        // quote keeps it data, not an FTS5 string delimiter.
        #expect(FTSQuery.match(for: "a\"b") == "\"a\"\"b\"*")
    }

    @Test func punctuationStaysInsideTheQuotedTerm() {
        // `&` is a tokenizer-irrelevant byte; wrapped in quotes it can't act as
        // an FTS5 operator and the term is still a well-formed prefix.
        #expect(FTSQuery.match(for: "rock & roll") == "\"rock\"* \"&\"* \"roll\"*")
    }
}
