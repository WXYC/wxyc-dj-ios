//
//  URLScrubbingTests.swift
//  WXYCAPITests
//
//  Pins URLScrubbing (issue #106): a query and/or fragment is stripped while
//  scheme/host/path survive, a URL with neither is left alone, and the
//  String overload only touches values that actually parse as a URL
//  carrying a query or fragment -- everything else (including arbitrary
//  NSError.userInfo prose) passes through untouched.
//
//  Created by Jake Bromberg on 08/19/26.
//  Copyright © 2026 WXYC. All rights reserved.
//

import Foundation
import Testing
@testable import WXYCAPI

@Suite("URL scrubbing")
struct URLScrubbingTests {
    @Test func stripsTheQueryString() {
        let url = URL(string: "https://api.wxyc.org/library/search?artist=Juana%20Molina")!
        let scrubbed = URLScrubbing.scrub(url)

        #expect(scrubbed.absoluteString == "https://api.wxyc.org/library/search")
    }

    @Test func stripsTheFragment() {
        let url = URL(string: "https://api.wxyc.org/library/search#results")!
        let scrubbed = URLScrubbing.scrub(url)

        #expect(scrubbed.absoluteString == "https://api.wxyc.org/library/search")
    }

    @Test func stripsBothQueryAndFragment() {
        let url = URL(string: "https://api.wxyc.org/library/search?artist=Jessica+Pratt#top")!
        let scrubbed = URLScrubbing.scrub(url)

        #expect(scrubbed.absoluteString == "https://api.wxyc.org/library/search")
    }

    @Test func preservesSchemeHostAndPath() {
        let url = URL(string: "https://api.wxyc.org/proxy/metadata/album?artistName=Chuquimamani-Condori")!
        let scrubbed = URLScrubbing.scrub(url)

        #expect(scrubbed.scheme == "https")
        #expect(scrubbed.host == "api.wxyc.org")
        #expect(scrubbed.path == "/proxy/metadata/album")
    }

    @Test func aURLWithNeitherQueryNorFragmentIsUnchanged() {
        let url = URL(string: "https://api.wxyc.org/djs/bin")!
        let scrubbed = URLScrubbing.scrub(url)

        #expect(scrubbed.absoluteString == url.absoluteString)
    }

    // MARK: - String overload (the userInfo walk)

    @Test func aNonURLStringIsReturnedUntouched() {
        #expect(URLScrubbing.scrub("No account matches that username") == "No account matches that username")
    }

    @Test func aBareWordWithNoSchemeIsReturnedUntouched() {
        // URL(string:) happily parses this as a relative-path URL with no
        // scheme -- it must not be mistaken for something to scrub.
        #expect(URLScrubbing.scrub("INVALID_OTP") == "INVALID_OTP")
    }

    @Test func aURLShapedStringWithAQueryIsScrubbed() {
        let scrubbed = URLScrubbing.scrub("https://api.wxyc.org/library/search?artist=Juana%20Molina")
        #expect(scrubbed == "https://api.wxyc.org/library/search")
    }

    @Test func aURLShapedStringWithAFragmentIsScrubbed() {
        let scrubbed = URLScrubbing.scrub("https://api.wxyc.org/library/search#results")
        #expect(scrubbed == "https://api.wxyc.org/library/search")
    }

    @Test func aURLShapedStringWithNeitherQueryNorFragmentIsUnchanged() {
        let value = "https://api.wxyc.org/djs/bin"
        #expect(URLScrubbing.scrub(value) == value)
    }
}
