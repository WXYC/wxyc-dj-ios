//
//  CatalogID.swift
//  WXYCAPI
//
//  The one parse of a catalog id written as digits, shared by the two places
//  an id arrives as text: a Spotlight item identifier (`CatalogSpotlight`)
//  and a `wxycdj://album/<id>` link (`DJAppLink`).
//
//  Created by Jake Bromberg on 10/08/26.
//  Copyright © 2026 WXYC. All rights reserved.
//

enum CatalogID {
    /// The id written as ASCII decimal digits, or `nil`. Stricter than
    /// `Int(_:)`, which also accepts a leading `+`/`-` and non-ASCII digits.
    /// `Int(_:)` still rejects the empty string and an overflowing value.
    static func decimal(_ digits: Substring) -> Int? {
        guard digits.allSatisfy({ $0.isASCII && $0.isNumber }) else { return nil }
        return Int(digits)
    }
}
