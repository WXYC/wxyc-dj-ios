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

// MARK: - AnalyticsPropertyValue

/// The closed set of shapes an ``AnalyticsEvent`` property may take.
///
/// There is deliberately no `.string(String)` case. A bare `.string` would
/// compile fine against `properties: ["query": typedText]` and ship a DJ's
/// search text straight to PostHog -- the same trap `TelemetryValue` closes
/// for Sentry's `extra` payload (see `ErrorReporting.swift`). Every string
/// this catalog ever emits is instead a case's `rawValue` off a closed
/// `RawRepresentable & CaseIterable` enum (`SignInMethod`, `SearchSource`,
/// ...), routed through ``enumString(_:)`` -- which captures the enum's
/// *entire* `allCases.rawValue` set alongside the one value actually chosen,
/// so the PII audit (`AnalyticsEventCatalogTests`) can verify a value is a
/// genuine member of a closed vocabulary without reaching back into
/// application code to ask what that vocabulary was.
enum AnalyticsPropertyValue: Sendable, Equatable {
    case int(Int)
    case bool(Bool)
    /// A value drawn from a closed Swift enum's `rawValue`, plus the enum's
    /// full `allCases.rawValue` set captured at construction. Construct this
    /// only through ``enumString(_:)`` -- the raw case exists so `Equatable`
    /// and pattern matching stay ordinary, not so a call site hand-assembles
    /// an arbitrary `(String, Set<String>)` pair.
    case enumString(String, allowedValues: Set<String>)

    /// Builds an ``enumString(_:allowedValues:)`` from a real enum case,
    /// deriving `allowedValues` from `E.allCases` -- the closed vocabulary
    /// the PII audit checks membership against. A future case added to `E`
    /// widens `allowedValues` automatically; it does not widen what a call
    /// site can pass as a bare string, because there is nothing here a call
    /// site *can* pass but a genuine `E` value.
    static func enumString<E: RawRepresentable & CaseIterable>(
        _ value: E
    ) -> AnalyticsPropertyValue where E.RawValue == String {
        .enumString(value.rawValue, allowedValues: Set(E.allCases.map(\.rawValue)))
    }

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
        case .enumString(let value, _): value
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
    /// carries it: `PostHogAnalytics.capture(_:)` stamps it onto every
    /// event's properties beside the event's own, so it has to clear this
    /// gate exactly like a typed property does. A property key a future
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

    /// Filters `properties` to PostHog's own `$`-prefixed context or this
    /// catalog's reviewed key set.
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
    /// on the event -- must be in ``allowedKeys`` or is dropped.
    static func filterNonSDKProperties(_ properties: [String: Any]) -> [String: Any] {
        properties.filter { key, _ in key.hasPrefix("$") || allowedKeys.contains(key) }
    }
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
