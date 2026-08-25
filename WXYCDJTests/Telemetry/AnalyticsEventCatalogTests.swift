//
//  AnalyticsEventCatalogTests.swift
//  WXYCDJTests
//
//  The issue-#108 PII audit: a parameterized test that walks every event
//  *registered in* `analyticsEventCatalog` (a hand-maintained array -- Swift
//  can't enumerate `AnalyticsEvent` conformers) and asserts every property
//  key is allowlisted and every enum-string value is a genuine member of
//  its own closed vocabulary. The free-text half of that claim is airtight:
//  a property that adds free text is unrepresentable by
//  `AnalyticsPropertyValue` at all, so it fails to *compile*, not merely to
//  pass this suite. The unallowlisted-key half only holds for an event that
//  is actually in the array -- an event added to the codebase but never
//  added here evades both this suite's forward check and its reverse
//  completeness check below whenever its properties reuse only keys
//  another catalog event already claims (issue #117 -- no bypass-proof
//  mechanism was found short of a production redesign, so this comment
//  states the real guarantee instead of the stronger one an earlier
//  version of it claimed). The `.enumString` membership assertion is a
//  separate, narrower guarantee -- see its own test below for what it
//  actually proves.
//
//  Also pins the pure mappers each event's file argues for beside itself:
//  `SignInFailureReason.init(_:)` and `MetadataEnrichmentMissingKind.init?(_:)`
//  are total switches over `AuthError`/`APIError`, `SearchSource.init(_:)`
//  mirrors `LibrarySearchOutcome.Source`, `CatalogRefreshCompletedEvent.from`
//  mirrors `CatalogRefreshService.Outcome`, and `ConnectivityTransition
//  .classify` is the RootView onChange decision that has no other test
//  harness.
//
//  Created by Jake Bromberg on 08/24/26.
//  Copyright © 2026 WXYC. All rights reserved.
//

import Foundation
import Testing
import WXYCAPI
@testable import WXYCDJ

/// One representative instance of every event in the wave-1 catalog. The
/// audit's job is key-and-shape coverage (every key this catalog can ever
/// emit is allowlisted), not exhaustive per-case value coverage — the
/// per-mapper `@Test(arguments:)` suites below own that for the two total
/// switches. A top-level constant (not a suite member) so `@Test(arguments:)`
/// can reference it directly.
private let analyticsEventCatalog: [any AnalyticsEvent] = [
    SignInCompletedEvent(method: .otp),
    SignInFailedEvent(method: .password, reason: .invalidCredentials),
    SearchPerformedEvent(source: .server, resultCount: 3, queryLength: 5),
    AlbumDetailViewedEvent(origin: .search, albumId: 100),
    BinItemAddedEvent(albumId: 100),
    BinItemRemovedEvent(albumId: 100),
    SpotlightDeeplinkOpenedEvent(cloneHit: true, parked: false),
    CatalogRefreshCompletedEvent(outcome: .refreshed, rowCount: 100, upserted: 5, removed: 1, trigger: .launch),
    MetadataEnrichmentMissingEvent(kind: .notFound),
    ArtworkURLRetiredEvent(source: .clone),
    OfflineLatchEngagedEvent(),
    ConnectivityRestoredEvent(),
]

@Suite("AnalyticsEvent catalog — PII audit")
struct AnalyticsEventCatalogTests {
    @Test("build_type is in the allowlist, even though no event carries it directly")
    func buildTypeIsAllowlisted() {
        #expect(AnalyticsPrivacyAllowlist.allowedKeys.contains("build_type"))
    }

    @Test("every catalog event's property keys are allowlisted", arguments: analyticsEventCatalog)
    func everyPropertyKeyIsAllowlisted(event: any AnalyticsEvent) {
        for key in event.properties.keys {
            #expect(
                AnalyticsPrivacyAllowlist.allowedKeys.contains(key),
                "\(type(of: event).name) has an unallowlisted property key: \(key)"
            )
        }
    }

    /// Issue #117: for every `AnalyticsEnum` conformer actually in this
    /// catalog today, this assertion holds **by construction** and cannot
    /// fail -- every real conformer is a `String` enum whose `CaseIterable`
    /// is synthesized, so `allowedValues` (`Set(Self.allCases.map(\.rawValue))`)
    /// is trivially a superset of any value that type can produce. It is
    /// not dead weight, though: a hand-written **struct** conforming to
    /// `AnalyticsEnum` can declare `allCases` as anything it likes,
    /// including empty, which is the one path free text can still reach
    /// `.enumString` through (`AnalyticsPropertyValue` has no `.string`
    /// case, but nothing stops a struct's `rawValue` from being arbitrary
    /// text). That is a real, if narrow, failure mode this assertion does
    /// catch -- `StructConformerMembershipTests` below constructs exactly
    /// such a conformer and proves the check goes red against it, rather
    /// than resting on this comment's word for it.
    @Test("every catalog event's enum-string values are genuine members of their own closed vocabulary", arguments: analyticsEventCatalog)
    func everyEnumStringValueIsAMemberOfItsOwnVocabulary(event: any AnalyticsEvent) {
        for (key, value) in event.properties {
            if case .enumString(let enumValue) = value {
                #expect(
                    enumValue.allowedValues.contains(enumValue.rawValue),
                    "\(type(of: event).name).\(key) = \(enumValue.rawValue) is not a member of \(enumValue.allowedValues)"
                )
            }
        }
    }

    /// The reverse direction of ``everyPropertyKeyIsAllowlisted``. Without it
    /// the allowlist can only go stale in one direction: a key left behind by
    /// a dropped event would pass unnoticed. It also catches the common case
    /// of a live event missing from `analyticsEventCatalog` above -- but only
    /// when that event introduces at least one property key no other catalog
    /// event already claims. Swift can't enumerate a protocol's conformers,
    /// so the catalog array is hand-maintained, and an event whose properties
    /// reuse only already-claimed keys evades this check (and
    /// ``everyPropertyKeyIsAllowlisted``'s forward direction) entirely if it's
    /// never added to the array -- issue #117, which looked for a
    /// bypass-proof mechanism and didn't find one cheap enough to be worth
    /// the redesign it would take.
    @Test("every allowlisted key is claimed by some event in the catalog")
    func everyAllowlistedKeyIsClaimedByAnEvent() {
        let claimed = Set(analyticsEventCatalog.flatMap(\.properties.keys))
        // `build_type` is the one deliberate exception: no event carries it,
        // TelemetryBootstrap.filterAnalyticsEvent stamps it in `beforeSend`.
        let unclaimed = AnalyticsPrivacyAllowlist.allowedKeys.subtracting(claimed).subtracting(["build_type"])
        #expect(unclaimed.isEmpty, "allowlisted but emitted by no catalog event: \(unclaimed.sorted())")
    }

    /// The app's own keys and posthog-ios's lifecycle-event keys are two
    /// separately-reviewed sets, and they must stay separate: if they ever
    /// overlapped, an app event could reach the wire on a key it was never
    /// audited for, just by reusing an SDK key's name.
    @Test("the app's allowlist and the SDK lifecycle allowance are disjoint")
    func allowlistAndSDKLifecycleKeysAreDisjoint() {
        #expect(AnalyticsPrivacyAllowlist.allowedKeys.isDisjoint(with: AnalyticsPrivacyAllowlist.sdkLifecycleKeys))
    }
}

/// A hand-written **struct** conforming to `AnalyticsEnum` with an empty
/// `allCases` -- the one path free text can reach `.enumString` through.
/// `AnalyticsEnum` only requires `RawRepresentable & CaseIterable &
/// Sendable where RawValue == String`; nothing about that requirement
/// forces `allCases` to actually enumerate every value the type can hold,
/// which is a guarantee Swift's synthesized `CaseIterable` gives an `enum`
/// for free and a hand-written conformance does not have to honor. `Self`
/// here is a struct, so `rawValue` can be constructed with any string at
/// all -- deliberately something that reads like typed search text, the
/// exact shape `AnalyticsPropertyValue` was designed to make
/// unrepresentable.
private struct FreeTextEnumConformer: AnalyticsEnum {
    let rawValue: String
    /// Empty on purpose -- see the type's doc comment.
    static let allCases: [FreeTextEnumConformer] = []
}

/// Issue #117: proves `everyEnumStringValueIsAMemberOfItsOwnVocabulary`'s
/// assertion (`enumValue.allowedValues.contains(enumValue.rawValue)`) has a
/// real failure mode, rather than resting on that test's doc comment to say
/// so. For every real `AnalyticsEnum` conformer in the wave-1 catalog the
/// assertion holds by construction and can never go red; this suite is what
/// demonstrates it *can* go red, against the one kind of conformer that can
/// actually violate it.
@Suite("AnalyticsEnum membership -- struct-conformer negative case")
struct StructConformerMembershipTests {
    @Test("a struct AnalyticsEnum conformer with an empty allCases is NOT a member of its own allowedValues")
    func freeTextConformerFailsMembership() {
        let value = FreeTextEnumConformer(rawValue: "typed search text a DJ entered")

        // This is the exact boolean expression
        // everyEnumStringValueIsAMemberOfItsOwnVocabulary's #expect uses.
        // Asserting it here is `false` is what proves that assertion is
        // capable of failing at all -- run against any of the twelve real
        // catalog events it can only ever come back `true`.
        #expect(!value.allowedValues.contains(value.rawValue))
    }

    @Test("...and the same conformer riding an AnalyticsPropertyValue reproduces the exact catalog-suite check")
    func freeTextConformerFailsTheRealCatalogAssertion() {
        let property: AnalyticsPropertyValue = .enumString(FreeTextEnumConformer(rawValue: "typed search text a DJ entered"))

        guard case .enumString(let enumValue) = property else {
            Issue.record("expected .enumString")
            return
        }
        #expect(!enumValue.allowedValues.contains(enumValue.rawValue))
    }
}

@Suite("SignInFailureReason")
struct SignInFailureReasonTests {
    @Test(arguments: [
        (AuthError.invalidCredentials, SignInFailureReason.invalidCredentials),
        (AuthError.rateLimited, .rateLimited),
        (AuthError.rejected(message: nil), .rejected),
        (AuthError.serverFailure(status: 500, message: nil), .server),
        (AuthError.missingSessionToken, .missingSessionToken),
        (AuthError.network(message: "boom"), .network),
        (AuthError.offline(message: "offline"), .offline),
        (AuthError.notSignedIn, .notSignedIn),
    ])
    func classifiesEveryAuthErrorCase(error: AuthError, expected: SignInFailureReason) {
        #expect(SignInFailureReason(error) == expected)
    }
}

@Suite("SearchSource")
struct SearchSourceTests {
    @Test(arguments: [
        (LibrarySearchOutcome.Source.server, SearchSource.server),
        (.local, .local),
    ])
    func mirrorsLibrarySearchOutcomeSource(source: LibrarySearchOutcome.Source, expected: SearchSource) {
        #expect(SearchSource(source) == expected)
    }
}

@Suite("MetadataEnrichmentMissingKind")
struct MetadataEnrichmentMissingKindTests {
    @Test(arguments: [
        (APIError.http(status: 404, message: nil), MetadataEnrichmentMissingKind.notFound),
        (APIError.http(status: 429, message: nil), .rateLimited),
        (APIError.decoding(detail: "boom"), .decodeFailed),
    ])
    func classifiesTheKindsLMLMissesReportOn(error: APIError, expected: MetadataEnrichmentMissingKind) {
        #expect(MetadataEnrichmentMissingKind(error) == expected)
    }

    @Test(arguments: [
        APIError.http(status: 500, message: nil),
        .unauthorized,
        .notSignedIn,
        .network("boom"),
        .offline(message: "offline"),
    ])
    func everythingElseIsNilNotAGuess(error: APIError) {
        #expect(MetadataEnrichmentMissingKind(error) == nil)
    }
}

@Suite("CatalogRefreshCompletedEvent.from")
struct CatalogRefreshCompletedEventMappingTests {
    @Test func upToDateCarriesNoRowData() {
        let event = CatalogRefreshCompletedEvent.from(outcome: .upToDate, trigger: .foreground)
        #expect(event.outcome == .upToDate)
        #expect(event.rowCount == 0)
        #expect(event.upserted == 0)
        #expect(event.removed == 0)
        #expect(event.trigger == .foreground)
    }

    @Test func refreshedCarriesTheRealDelta() {
        let event = CatalogRefreshCompletedEvent.from(
            outcome: .refreshed(rowCount: 4200, upserted: 17, removed: 3),
            trigger: .background
        )
        #expect(event.outcome == .refreshed)
        #expect(event.rowCount == 4200)
        #expect(event.upserted == 17)
        #expect(event.removed == 3)
        #expect(event.trigger == .background)
    }

    @Test func skippedEmptyExportCarriesNoRowData() {
        let event = CatalogRefreshCompletedEvent.from(outcome: .skippedEmptyExport, trigger: .launch)
        #expect(event.outcome == .skippedEmpty)
        #expect(event.rowCount == 0)
    }

    @Test func failedCarriesNoRowDataEither() {
        let event = CatalogRefreshCompletedEvent.failed(trigger: .background)
        #expect(event.outcome == .failed)
        #expect(event.rowCount == 0)
        #expect(event.upserted == 0)
        #expect(event.removed == 0)
    }
}

@Suite("ConnectivityTransition.classify")
struct ConnectivityTransitionTests {
    @Test func onlineToOfflineIsEngaged() {
        #expect(ConnectivityTransition.classify(wasOnline: true, isOnline: false) == .engaged)
    }

    @Test func offlineToOnlineIsRestored() {
        #expect(ConnectivityTransition.classify(wasOnline: false, isOnline: true) == .restored)
    }

    @Test(arguments: [(true, true), (false, false)])
    func aSteadyStateIsNoTransition(wasOnline: Bool, isOnline: Bool) {
        #expect(ConnectivityTransition.classify(wasOnline: wasOnline, isOnline: isOnline) == nil)
    }
}
