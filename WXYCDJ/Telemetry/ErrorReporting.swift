//
//  ErrorReporting.swift
//  WXYCDJ
//
//  The app's error-reporting seam (issue #106): a small Sendable protocol
//  every capture site calls, a closed value type for the only "extra" data
//  a call site may attach, and the pure classification that turns a package
//  error into something safe to hand a crash reporter. Deliberately no
//  Sentry import here -- everything in this file is Foundation-only, so
//  WXYCDJTests can exercise it through `@testable import WXYCDJ` without
//  the app-target-only Sentry link the rest of this package avoids handing
//  to the test bundle (see project.yml's Sentry package comment).
//
//  Modeled on wxyc-ios-64's Shared/Logger/Sources/Logger/ErrorReporter.swift,
//  simplified for this app's smaller surface and its seam-injection
//  convention (TokenStorage, RequestSession, PathProvider, ...) rather than
//  that package's process-wide ErrorReporting.shared holder -- AppDependencies
//  owns one `errorReporter` instance and hands it down, so nothing here needs
//  a global.
//
//  Created by Jake Bromberg on 08/19/26.
//  Copyright © 2026 WXYC. All rights reserved.
//

import Foundation
import WXYCAPI

// MARK: - ErrorReporter

/// A single entry point for reporting a defect to crash/error-reporting
/// backends. Capture sites call this beside their existing `os_log` call
/// (see AppDependencies.catalogErrorDetail's callers for the pattern this
/// mirrors); it never replaces the log line, which stays the on-device
/// diagnostic of record.
///
/// `Sendable` on purpose: conformers hold no mutable state of their own (the
/// SDK singleton `SentryErrorReporter` wraps does its own internal
/// synchronization), so a capture site on any isolation --
/// `@MainActor`-isolated view models, `AppDependencies`, a `nonisolated`
/// helper -- can call `report` directly with no actor hop.
protocol ErrorReporter: Sendable {
    /// Reports `error` to the configured backend(s).
    ///
    /// - Parameters:
    ///   - error: The error to report. See ``SentryErrorReporter`` for how a
    ///     package `AuthError`/`APIError` is curated before it reaches the
    ///     SDK -- this parameter accepts the *original* error; classification
    ///     is the reporter's job, not the call site's.
    ///   - context: A short, fixed label for where/why the error occurred
    ///     (e.g. `"AppDependencies.refreshCatalog"`). **Deliberately a
    ///     `StaticString`, not a `String`.** A `StaticString` can only be
    ///     spelled as a literal in source, so it can never carry interpolated
    ///     runtime content -- a DJ's search text, a server message, a URL. A
    ///     dynamic context string being reportable would be a *review*
    ///     obligation (someone has to notice the interpolation and object);
    ///     this makes it a *compile* obligation instead, the same shape as
    ///     this package's total `caseName` switches and `ArtworkFailureClassification`.
    ///   - extra: Structured, closed-vocabulary detail beyond the error
    ///     itself. See ``TelemetryValue`` for why free text can't ride in
    ///     here either.
    func report(_ error: any Error, context: StaticString, extra: [String: TelemetryValue])
}

extension ErrorReporter {
    /// Convenience for the common case of no additional structured detail.
    func report(_ error: any Error, context: StaticString) {
        report(error, context: context, extra: [:])
    }
}

// MARK: - TelemetryValue

/// The closed set of shapes a capture site may attach as `extra` detail.
///
/// There is deliberately no `.string(String)` case. `ErrorReporter.report`'s
/// `context` is already a `StaticString` so a dynamic label can't leak
/// through there; `TelemetryValue` closes the other door a call site might
/// reach for -- `extra: ["query": userTypedText]` would compile fine against
/// a `[String: String]` dictionary and ship a DJ's search text straight to
/// Sentry. `.string` instead only accepts a `StaticString`, for the same
/// compile-time reason `context` does.
///
/// ``errorIdentity(domain:code:)`` exists because `AppDependencies
/// .catalogErrorDetail(_:)` already assembles exactly this pair (an
/// `NSError`'s domain + numeric code) for `os_log`, and a capture site
/// wanting to attach the same fact as structured Sentry detail shouldn't
/// have to flatten it into a string first. The error's own detail should
/// usually travel as the error object itself -- Sentry captures an
/// `NSError`'s domain/code/underlying-error chain natively -- so reach for
/// this case only when the reporter needs that fact *beside* a different
/// primary error (e.g. tagging which sub-store failed inside a composite
/// failure), not as a substitute for passing the real error.
enum TelemetryValue: Sendable, Equatable {
    case int(Int)
    case bool(Bool)
    case string(StaticString)
    case errorIdentity(domain: String, code: Int)
}

// StaticString has no built-in Equatable/Hashable conformance (it's not
// meaningfully comparable at the type's own level -- two literals with the
// same text aren't guaranteed pointer-identical). Compare by rendered text,
// which is all a test needs and the only thing that could differ.
extension TelemetryValue {
    static func == (lhs: TelemetryValue, rhs: TelemetryValue) -> Bool {
        switch (lhs, rhs) {
        case (.int(let l), .int(let r)):
            return l == r
        case (.bool(let l), .bool(let r)):
            return l == r
        case (.string(let l), .string(let r)):
            return "\(l)" == "\(r)"
        case (.errorIdentity(let ld, let lc), .errorIdentity(let rd, let rc)):
            return ld == rd && lc == rc
        default:
            return false
        }
    }
}

// MARK: - NoOpErrorReporter

/// Discards every report. The default everywhere a real reporter isn't
/// explicitly wired in -- see AppDependencies' two test-facing initializers,
/// which default to this rather than ``SentryErrorReporter`` so unit tests
/// (including the store-open degrade tests that exercise exactly the paths a
/// capture site lives on) never fire a real Sentry event.
struct NoOpErrorReporter: ErrorReporter {
    func report(_ error: any Error, context: StaticString, extra: [String: TelemetryValue]) {
        // Intentionally empty.
    }
}

// MARK: - Curated error classification

/// The pure, SDK-free half of ``SentryErrorReporter``'s privacy contract:
/// turning a package `AuthError`/`APIError` into something safe to hand
/// `SentrySDK.capture(error:)`.
///
/// This exists as a standalone type (rather than inline in
/// `SentryErrorReporter.report`) for two reasons. First, testability: it
/// touches no Sentry type, so `WXYCDJTests` can assert its output directly
/// without the SDK link this design avoids handing the test target (see this
/// file's header). Second, and more load-bearing: **`SentrySDK.capture(error:)`
/// must never see a raw `AuthError`/`APIError`.** Sentry builds
/// `exception.value` (and `mechanism.desc`) from `String(describing: error)`
/// on a bridged Swift error -- so `AuthError.rejected(message: "<server
/// copy>")` would ship that copy verbatim in the event's headline text,
/// regardless of any `caseName` mapping applied elsewhere. Routing every
/// capture through ``curated(_:)`` first is what keeps that string from ever
/// reaching the SDK boundary.
enum TelemetryErrorClassification {
    /// The controlled `NSError` domains this reporter ever constructs.
    /// `URLError`'s own domain (`NSURLErrorDomain`) passes through
    /// unmodified -- see ``curated(_:)`` -- so it is not listed here.
    enum Domain {
        static let authError = "org.wxyc.dj.AuthError"
        static let apiError = "org.wxyc.dj.APIError"
    }

    /// Returns the error `SentryErrorReporter` should actually capture for
    /// `error`.
    ///
    /// - An `AuthError` or `APIError` is replaced with a **curated
    ///   `NSError`**: a controlled domain (``Domain``), a code derived
    ///   deterministically from the case name (see ``stableCode(for:)``),
    ///   and an allowlisted `userInfo` carrying only the case name and (when
    ///   present) the HTTP status -- both read off `error.caseName`, which is
    ///   this package's own total-switch mapping that already strips every
    ///   message-bearing associated value (`AuthError.rejected(message:)`,
    ///   `.serverFailure(status:message:)`, `APIError.http(status:message:)`).
    ///   Going through `caseName` rather than switching on the raw case here
    ///   is deliberate: it is the one place in the package permitted to read
    ///   those cases' payloads, so a second switch here would be a second
    ///   place a future edit could accidentally read `message` back into
    ///   scope.
    /// - A `URLError` passes through **unchanged**. The domain/code bridge is
    ///   exactly what's wanted for a transport failure (`NSURLErrorDomain`
    ///   code `-1009` reads as "offline" at a glance in Sentry); the URL(s) it
    ///   may carry in `userInfo` are handled downstream by the `beforeSend`
    ///   walk (`TelemetryPrivacyScrub`), not here.
    /// - Anything else passes through unchanged: no other error type in this
    ///   app carries a message-bearing case this classification needs to
    ///   strip.
    static func curated(_ error: any Error) -> any Error {
        if let authError = error as? AuthError {
            return curatedError(domain: Domain.authError, caseName: authError.caseName)
        }
        if let apiError = error as? APIError {
            return curatedError(domain: Domain.apiError, caseName: apiError.caseName)
        }
        return error
    }

    private static func curatedError(domain: String, caseName: AuthError.CaseName) -> NSError {
        curatedError(domain: domain, name: caseName.name, statusCode: caseName.statusCode)
    }

    private static func curatedError(domain: String, caseName: APIError.CaseName) -> NSError {
        curatedError(domain: domain, name: caseName.name, statusCode: caseName.statusCode)
    }

    private static func curatedError(domain: String, name: String, statusCode: Int?) -> NSError {
        var userInfo: [String: Any] = ["caseName": name]
        if let statusCode {
            userInfo["statusCode"] = statusCode
        }
        return NSError(domain: domain, code: stableCode(for: name), userInfo: userInfo)
    }

    /// A deterministic, process-stable numeric code for a case name.
    ///
    /// Deliberately **not** `String.hashValue` -- Swift salts that per
    /// process (the same gotcha `CatalogSpotlight.fingerprint` documents for
    /// `CatalogRow.hashValue`), which would give the same `AuthError` case a
    /// different code on every launch and defeat Sentry's issue grouping.
    /// FNV-1a is a plain byte-wise hash with no per-process seed, so the same
    /// case name always yields the same code -- across launches, devices, and
    /// Swift versions -- with no table to keep in sync as the package's error
    /// enums grow new cases. A collision between two case names is possible
    /// in principle (32 bits truncated to 31) but immaterial here: the code
    /// only needs to group Sentry issues usefully, not uniquely identify a
    /// case on its own -- `userInfo["caseName"]` is what actually names it.
    static func stableCode(for name: String) -> Int {
        var hash: UInt32 = 0x811c9dc5
        for byte in name.utf8 {
            hash ^= UInt32(byte)
            hash = hash &* 0x0100_0193
        }
        return Int(hash & 0x7fff_ffff)
    }
}
