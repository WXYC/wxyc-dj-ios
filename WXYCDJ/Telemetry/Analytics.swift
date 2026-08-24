//
//  Analytics.swift
//  WXYCDJ
//
//  The app's product-analytics seam (issue #108): a small Sendable protocol
//  every capture site calls, a closed value type for what an event property
//  is allowed to be, and the pure allowlist filter PostHogAnalytics wires
//  into PostHog's `beforeSend`. Deliberately no PostHog import here --
//  everything in this file is Foundation-only, so WXYCDJTests can exercise
//  the filter and the property-value shapes through `@testable import
//  WXYCDJ` without the app-target-only PostHog link the rest of this
//  package avoids handing to the test bundle (see project.yml's PostHog
//  package comment, and ErrorReporting.swift's identical argument for the
//  Sentry seam this mirrors).
//
//  Modeled on wxyc-ios-64's StructuredPostHogAnalytics pattern, adapted to
//  this app's smaller event catalog and its seam-injection convention
//  (TokenStorage, RequestSession, PathProvider, ErrorReporter, ...).
//
//  Created by Jake Bromberg on 08/24/26.
//  Copyright © 2026 WXYC. All rights reserved.
//

import Foundation

// MARK: - AnalyticsEvent

/// One entry in the wave-1 event catalog (`AnalyticsEvents.swift`). A
/// conformer is a small struct naming one PostHog event and the closed set
/// of properties it carries -- see that file for the full catalog and the
/// argued reasoning behind each event.
protocol AnalyticsEvent: Sendable {
    /// The PostHog event name. `static` because it's a property of the
    /// *type*, not a particular instance -- every `SearchPerformedEvent`
    /// names the same event, whatever its `source`/`resultCount` are.
    static var name: String { get }
    /// This instance's properties, keyed by the wire property name
    /// (`snake_case`, matching PostHog convention). Every value is an
    /// ``AnalyticsPropertyValue`` -- see that type for why a free-text case
    /// doesn't exist to reach for.
    var properties: [String: AnalyticsPropertyValue] { get }
}

// MARK: - Analytics

/// A single entry point for recording a product event. Capture sites call
/// this the same way they call `ErrorReporter.report` -- on any isolation,
/// no actor hop, because a conformer holds no mutable state of its own (the
/// SDK singleton `PostHogAnalytics` wraps does its own internal
/// synchronization).
protocol Analytics: Sendable {
    /// Records `event`. `some AnalyticsEvent` (protocol-requirement opaque
    /// parameter sugar for a generic method) lets a conformer read
    /// `E.name`/`E.self` off the concrete type rather than only the
    /// existential -- `PostHogAnalytics` uses that to key the PostHog
    /// `capture(_:properties:)` call on the *type's* event name.
    func capture(_ event: some AnalyticsEvent)
}

// MARK: - AnalyticsEnum

/// The only kind of string an ``AnalyticsEvent`` property may carry: a case
/// of a closed Swift enum whose whole vocabulary is enumerable.
///
/// This exists so ``AnalyticsPropertyValue/enumString(_:)``'s payload can be
/// typed as `any AnalyticsEnum` rather than a `String`. That is the whole
/// mechanism: `.enumString(typedText)` is a **compile** error ("argument type
/// 'String' does not conform to expected type 'AnalyticsEnum'"), not a review
/// obligation — the same bar `TelemetryValue.string(StaticString)` sets on the
/// Sentry side, where a `StaticString` can only be spelled as a source literal.
/// An earlier shape carried `(String, allowedValues: Set<String>)` and asked,
/// in a doc comment, that call sites only use a factory; a hand-built
/// `.enumString(typedText, allowedValues: [typedText])` compiled *and* passed
/// the PII audit, which is exactly the failure mode ADR 0007 says never to
/// hold by comment.
protocol AnalyticsEnum: RawRepresentable, CaseIterable, Sendable where RawValue == String {}

extension AnalyticsEnum {
    /// The enum's entire vocabulary, for the PII audit
    /// (`AnalyticsEventCatalogTests`) to check a value's membership against
    /// without reaching back into application code to ask what that
    /// vocabulary was. Derived on demand rather than stored on every value.
    var allowedValues: Set<String> { Set(Self.allCases.map(\.rawValue)) }
}

// MARK: - AnalyticsPropertyValue

/// The closed set of shapes an ``AnalyticsEvent`` property may take.
///
/// There is deliberately no `.string(String)` case. A bare `.string` would
/// compile fine against `properties: ["query": typedText]` and ship a DJ's
/// search text straight to PostHog -- the same trap `TelemetryValue` closes
/// for Sentry's `extra` payload (see `ErrorReporting.swift`). Every string
/// this catalog ever emits is instead a case of an ``AnalyticsEnum``
/// (`SignInMethod`, `SearchSource`, ...), which is the *only* thing
/// ``enumString(_:)`` accepts.
enum AnalyticsPropertyValue: Sendable, Equatable {
    case int(Int)
    case bool(Bool)
    /// A case of a closed ``AnalyticsEnum``. The existential payload is what
    /// makes free text unrepresentable here rather than merely discouraged --
    /// see ``AnalyticsEnum``.
    case enumString(any AnalyticsEnum)

    /// This value as a plain Foundation type, for handing to
    /// `PostHogSDK.capture(_:properties:)`'s `[String: Any]?`. Foundation
    /// on purpose (not a PostHog type) -- this conversion lives in the
    /// PostHog-free half of the seam so the belt test
    /// (`PostHogPrivacyPipelineTests`) can assert on it without linking the
    /// SDK.
    var wireValue: Any {
        switch self {
        case .int(let value): value
        case .bool(let value): value
        case .enumString(let value): value.rawValue
        }
    }

    /// Hand-written because `any AnalyticsEnum` isn't `Equatable`, so the
    /// synthesized conformance can't be used. Switches on `lhs` alone -- never
    /// a `(lhs, rhs)` tuple with a `default:` -- so a fourth case is a compile
    /// error here until this function grows an arm for it, rather than two
    /// unequal values silently comparing equal. `.enumString` compares the
    /// **type as well as** the raw value, so two different vocabularies that
    /// happen to share a spelling (`SearchSource.local` and some future
    /// `…Origin.local`) are never equal.
    static func == (lhs: AnalyticsPropertyValue, rhs: AnalyticsPropertyValue) -> Bool {
        switch lhs {
        case .int(let left):
            if case .int(let right) = rhs { return left == right }
            return false
        case .bool(let left):
            if case .bool(let right) = rhs { return left == right }
            return false
        case .enumString(let left):
            if case .enumString(let right) = rhs {
                return type(of: left) == type(of: right) && left.rawValue == right.rawValue
            }
            return false
        }
    }
}

// MARK: - AnalyticsPrivacyAllowlist

/// The runtime backstop behind the typed-event layer above (issue #108's
/// review-facing summary: "every property is an enum string, a number, or a
/// boolean, enforced by a parameterized test -- not by reviewer diligence").
/// `AnalyticsEventCatalogTests` is the parameterized test that walks the
/// catalog against ``allowedKeys``; `filterNonSDKProperties(_:)` is what
/// `PostHogAnalytics` wires into `PostHogConfig.setBeforeSend([...])` so the
/// same allowlist holds even if a future event's `properties` dict is built
/// wrong despite the type system (a typo'd key, a merge that reintroduces a
/// stray field) -- the event ships filtered rather than ships wrong.
enum AnalyticsPrivacyAllowlist {
    /// Every property key any event in the wave-1 catalog may emit --
    /// `build_type` included, even though no individual `AnalyticsEvent`
    /// carries it: `TelemetryBootstrap.filterAnalyticsEvent(_:)` stamps it
    /// onto every event as it passes through `beforeSend`, so it has to clear
    /// this gate exactly like a typed property does. A property key a future
    /// event wants to add is not usable until it's added here -- the point
    /// of the allowlist being separate from the event's own struct fields.
    static let allowedKeys: Set<String> = [
        "build_type",
        "method",
        "reason",
        "source",
        "result_count",
        "query_length",
        "origin",
        "album_id",
        "clone_hit",
        "parked",
        "outcome",
        "row_count",
        "upserted",
        "removed",
        "trigger",
        "kind",
    ]

    /// The properties **posthog-ios itself** attaches to the application
    /// lifecycle events `captureApplicationLifecycleEvents = true` turns on --
    /// verified against `PostHogAppLifeCycleIntegration.swift` in the pinned
    /// 3.69.x SDK, which is the only source of non-`$` keys this app does not
    /// author.
    ///
    /// A **separate, separately-reviewed** constant rather than more entries in
    /// ``allowedKeys``, for two reasons. First, it keeps ``allowedKeys``
    /// meaning exactly "keys this app's own catalog emits," which is the set
    /// `AnalyticsEventCatalogTests` audits in both directions. Second, the two
    /// are asserted **disjoint** by that suite, so no app event can ever reach
    /// the wire by reusing a lifecycle key's name.
    ///
    /// Every member is a `Bundle.main` version string or a `Bool` -- the same
    /// class of data as the `$app_version` / `$app_build` already in PostHog's
    /// static context, which passes untouched under the `$` carve-out below.
    /// Nothing here is or can become personal data. Without them the lifecycle
    /// events still arrive but are gutted: `Application Opened` loses
    /// `from_background`, the only thing separating a cold launch from a
    /// foreground resume, and `Application Updated` loses which build a DJ
    /// upgraded *from*. That is the entire reason those events were left on.
    ///
    /// This is a named allowance, not a loosening: the mechanism is still
    /// "drop every non-`$` key that isn't on a reviewed list."
    static let sdkLifecycleKeys: Set<String> = [
        "version",
        "build",
        "previous_version",
        "previous_build",
        "from_background",
    ]

    /// Filters `properties` to PostHog's own `$`-prefixed context, this
    /// catalog's reviewed key set, or the reviewed SDK-lifecycle key set.
    ///
    /// Scoping to non-`$` keys is load-bearing, not incidental: PostHog's
    /// `beforeSend` runs over the *fully merged* property dict, after its
    /// internal `buildProperties` has already folded in `$app_version` /
    /// `$os_version` / `$device_type` / `$locale` / `$session_id` and,
    /// crucially, `$process_person_profile: false` -- the flag the app's
    /// `personProfiles = .never` contract item depends on landing on every
    /// event. A blanket allowlist (one that didn't carve out `$`-prefixed
    /// keys) would strip that flag along with the SDK context, which is
    /// exactly backwards: those are the two things `beforeSend` must not
    /// touch. Every other key -- everything this app's own capture sites put
    /// on the event -- must be in ``allowedKeys`` (or, for the SDK's own
    /// lifecycle events, ``sdkLifecycleKeys``) or is dropped.
    ///
    /// The carve-out has exactly one exception, ``personPayloadKeys`` -- see
    /// its doc comment for why `$set` / `$set_once` / `$groups` are person
    /// data rather than SDK context, and why `personProfiles = .never` does
    /// not already cover them.
    static func filterNonSDKProperties(_ properties: [String: Any]) -> [String: Any] {
        properties.filter { key, _ in
            if personPayloadKeys.contains(key) { return false }
            return key.hasPrefix("$") || allowedKeys.contains(key) || sdkLifecycleKeys.contains(key)
        }
    }

    /// The three `$`-prefixed keys that are **person data**, not SDK context,
    /// and are therefore the one exception to the carve-out above.
    ///
    /// `personProfiles = .never` suppresses the *flag* (`$process_person_profile`
    /// is forced `false`) but **not the payload**: `PostHogSDK.buildProperties`
    /// sets `$set` / `$set_once` / `$groups` from a `capture(...)` call's
    /// `userProperties` / `userPropertiesSetOnce` / `groups` with no
    /// person-processing gate at all, and `captureInternal` calls
    /// `requirePersonProcessing()` purely for its warning log -- the result is
    /// discarded. So under `.never` a raw `PostHogSDK.shared.capture(...)`
    /// carrying `userProperties` ships the person payload *and*
    /// `$process_person_profile: false` side by side. Verified against the
    /// pinned 3.69.10 source, not inferred from the docs.
    ///
    /// Nothing in this app passes `userProperties` today -- ``PostHogAnalytics``
    /// calls the two-argument `capture(_:properties:)`. That is exactly the
    /// reason to close it here rather than rely on it: `PostHogSDK.shared` is a
    /// global reachable from anywhere in the app target, the SDK's own lifecycle
    /// events already demonstrate that bypassing the conformer is normal, and
    /// "nobody calls it that way" is the comment-enforced invariant ADR 0007
    /// exists to forbid.
    static let personPayloadKeys: Set<String> = ["$set", "$set_once", "$groups"]
}

// MARK: - NoOpAnalytics

/// Discards every capture. The default everywhere a real ``Analytics``
/// isn't explicitly wired in -- mirrors ``NoOpErrorReporter``'s rationale:
/// unit tests (including every existing view-model construction site) never
/// fire a real PostHog event just by instantiating a view model.
struct NoOpAnalytics: Analytics {
    func capture(_ event: some AnalyticsEvent) {
        // Intentionally empty.
    }
}
