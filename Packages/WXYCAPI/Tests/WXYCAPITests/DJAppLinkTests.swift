//
//  DJAppLinkTests.swift
//  WXYCAPITests
//
//  Pins the `wxycdj://album/<id>` parse (issue #186): the one URL shape the
//  listener app sends, accepted exactly, and every near miss rejected. The
//  scheme literal also lives in wxyc-ios-64 with no shared source, so this
//  table is half of the guard that keeps the two from drifting.
//
//  Created by Jake Bromberg on 10/08/26.
//  Copyright © 2026 WXYC. All rights reserved.
//

import Foundation
import Testing
@testable import WXYCAPI

@Suite("DJAppLink")
struct DJAppLinkTests {
    @Test func schemeIsPinned() {
        #expect(DJAppLink.scheme == "wxycdj")
    }

    @Test(arguments: [
        ("wxycdj://album/123", 123),
        ("wxycdj://album/1", 1),
        // Schemes and hosts are case-insensitive.
        ("WXYCDJ://ALBUM/42", 42),
    ])
    func acceptsAnAlbumLink(link: String, expected: Int) throws {
        let url = try #require(URL(string: link))
        #expect(DJAppLink.albumID(from: url) == expected)
    }

    @Test(arguments: [
        "wxyc://album/123",                          // the listener app's own scheme
        "https://dj.wxyc.org/album/123",             // not a custom-scheme link
        "wxycdj://artist/123",                       // wrong host
        "wxycdj://album",                            // missing id
        "wxycdj://album/",                           // empty id
        "wxycdj://album/0",                          // not a catalog id
        "wxycdj://album/-5",                         // Int(_:) accepts a sign; we don't
        "wxycdj://album/+5",
        "wxycdj://album/abc",
        "wxycdj://album/12.3",
        "wxycdj://album/123/bin",                    // extra path component
        "wxycdj://album/123/",
        "wxycdj://album/123?add=1",                  // nothing rides along with the id
        "wxycdj://album/123#x",
        "wxycdj://album/99999999999999999999999",    // overflows Int
    ])
    func rejectsEverythingElse(link: String) throws {
        let url = try #require(URL(string: link))
        #expect(DJAppLink.albumID(from: url) == nil)
    }
}
