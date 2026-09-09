//
//  BuildEnvironmentTests.swift
//  WXYCDJTests
//
//  Pins BuildEnvironment's classification table (issue #106). The
//  development case is proven by ``current`` itself, since this test target
//  always builds DEBUG; the testflight/production split is proven through
//  ``BuildEnvironment/classify(receiptURL:)``'s pure, parameter-driven core
//  so the table doesn't need a real sandbox receipt on disk.
//
//  Created by Jake Bromberg on 08/19/26.
//  Copyright © 2026 WXYC. All rights reserved.
//

import Foundation
import Testing
@testable import WXYCDJ

@Suite("BuildEnvironment")
struct BuildEnvironmentTests {
    /// WXYCDJTests is itself a `DEBUG` build (see the CI / pre-push
    /// checks), so ``BuildEnvironment/current`` should read `.development`
    /// unconditionally under this test target -- pinning that is what makes
    /// ``classify(receiptURL:)`` (below) the *only* place the
    /// testflight/production split needs to live, since `current` never
    /// reaches that branch here.
    @Test func currentIsDevelopmentUnderThisDebugTestTarget() {
        #expect(BuildEnvironment.current == .development)
    }

    @Test(arguments: [
        (receiptURL: URL?.none, expected: BuildEnvironment.production),
        (receiptURL: URL(string: "file:///private/var/mobile/Containers/Data/Application/ABC/StoreKit/sandboxReceipt"), expected: .testflight),
        (receiptURL: URL(string: "file:///private/var/mobile/Containers/Data/Application/ABC/StoreKit/receipt"), expected: .production),
        (receiptURL: URL(string: "file:///private/var/mobile/Containers/Data/Application/ABC/StoreKit/receipt-sandboxReceipt"), expected: .production),
    ])
    func classifyReceiptURL(receiptURL: URL?, expected: BuildEnvironment) {
        #expect(BuildEnvironment.classify(receiptURL: receiptURL) == expected)
    }
}
