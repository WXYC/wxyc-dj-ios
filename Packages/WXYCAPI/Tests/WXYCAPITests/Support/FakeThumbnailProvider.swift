//
//  FakeThumbnailProvider.swift
//  WXYCAPITests
//
//  A canned ThumbnailProviding double for the CatalogRefreshService cacheThumbnail
//  tests (issue #44). Returns a configured local file URL per album id (or nil for
//  a miss) and records which rows were resolved, so a test can assert the lazy
//  upsert read the right bytes without standing up a real fetch. Lock-guarded
//  Sendable, matching the other doubles.
//
//  Created by Jake on 06/24/26.
//  Copyright © 2026 WXYC. All rights reserved.
//

import Foundation
import os
@testable import WXYCAPI

final class FakeThumbnailProvider: ThumbnailProviding, @unchecked Sendable {
    private let urls: [Int: URL]
    private let resolved = OSAllocatedUnfairLock(initialState: [Int]())

    /// Map album id -> the cached file URL to hand back (absent id => nil, a miss).
    init(urls: [Int: URL] = [:]) {
        self.urls = urls
    }

    /// The album ids `localThumbnailURL(for:)` was asked to resolve, in order.
    var resolvedIDs: [Int] { resolved.withLock { $0 } }

    func localThumbnailURL(for row: CatalogRow) async -> URL? {
        resolved.withLock { $0.append(row.id) }
        return urls[row.id]
    }
}
