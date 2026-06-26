//
//  StubPathProvider.swift
//  WXYCAPITests
//
//  A PathProvider that captures ConnectivityMonitor's onUpdate closure so a test
//  can push satisfied/unsatisfied path transitions deterministically instead of
//  depending on the real NWPathMonitor.
//
//  Created by Jake on 6/26/26.
//  Copyright © 2026 WXYC. All rights reserved.
//

import Foundation
import os
@testable import WXYCAPI

/// Captures the `onUpdate` callback registered by ``ConnectivityMonitor/start``
/// and replays path transitions on demand via ``send(satisfied:)``.
public final class StubPathProvider: PathProvider {
    private let handler = OSAllocatedUnfairLock<(@Sendable (Bool) -> Void)?>(initialState: nil)

    public init() {}

    public func start(onUpdate: @escaping @Sendable (Bool) -> Void) {
        handler.withLock { $0 = onUpdate }
    }

    /// Push a path transition to the captured handler. A no-op before `start`.
    public func send(satisfied: Bool) {
        let handler = handler.withLock { $0 }
        handler?(satisfied)
    }
}
