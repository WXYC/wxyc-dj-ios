//
//  BuildEnvironment.swift
//  WXYCDJ
//
//  Answers one question for TelemetryBootstrap: is this developer traffic or
//  a real DJ? Sentry's `environment` option defaults to "production" when
//  left unset, so a debug run or a TestFlight build would otherwise file
//  under real user traffic and pollute triage -- the same lesson
//  wxyc-ios-64/Shared/Core/Sources/Core/BuildEnvironment.swift records at
//  length for its own five-case version.
//
//  Deliberately a minimal three-case port, not that file ported verbatim:
//  this app has no ad-hoc/Profile-action distribution channel to distinguish,
//  and Simulator vs. an Xcode-run device build both mean the same thing here
//  ("a developer is looking at this"), so there is no case the two need
//  splitting into that ``current`` couldn't already tell from ``current``
//  alone if a future need arose. Kept whole in the app layer rather than
//  split into WXYCAPI: it has exactly one caller (``TelemetryBootstrap``),
//  and it reads `Bundle.main`, which has no meaning inside a Foundation
//  package that also runs under `swift test` on the host.
//
//  Created by Jake Bromberg on 08/19/26.
//  Copyright © 2026 WXYC. All rights reserved.
//

import Foundation

/// Which kind of build is running, as Sentry's `environment` tag wants it.
enum BuildEnvironment: String, Sendable {
    /// A `DEBUG`-configured build -- an Xcode run, on the Simulator or a
    /// device. Not "real DJ" traffic under any circumstance this app ships.
    case development
    /// A release archive installed through TestFlight: a genuine tester
    /// report, but not one that needs a store submission to reach.
    case testflight
    /// A release archive installed from the App Store. Real DJs, at last.
    case production

    /// The environment this process is actually running in. Computed once --
    /// every fact behind it is fixed for the process's lifetime.
    static let current: BuildEnvironment = {
        #if DEBUG
        return .development
        #else
        return classify(receiptURL: Bundle.main.appStoreReceiptURL)
        #endif
    }()

    /// The pure core of the classification: given only the App Store receipt
    /// URL, decide testflight vs. production.
    ///
    /// Deliberately **not** wrapped in `#if DEBUG` itself, even though
    /// ``current`` only ever calls it from the `#else` branch above. If this
    /// function also special-cased debug builds internally, it would always
    /// answer `.development` under a test target -- WXYCDJTests is itself a
    /// `DEBUG` build -- which would make the testflight/production split
    /// untestable no matter what receipt URL a test constructed. Taking the
    /// receipt URL as a parameter (rather than reading
    /// `Bundle.main.appStoreReceiptURL` internally) is what turns this into a
    /// table: a test can assert both outcomes without needing a real sandbox
    /// receipt on disk.
    ///
    /// A sandbox receipt is written under a file literally named
    /// `sandboxReceipt` -- matched on the file name alone since the
    /// containing directory differs across OS versions, and a bare directory
    /// listing is what TestFlight/Xcode installs actually differ on. A `nil`
    /// or non-sandbox URL (including every App Store install, which carries
    /// `receipt`, not `sandboxReceipt`) reads as production.
    static func classify(receiptURL: URL?) -> BuildEnvironment {
        receiptURL?.lastPathComponent == sandboxReceiptName ? .testflight : .production
    }

    private static let sandboxReceiptName = "sandboxReceipt"
}
