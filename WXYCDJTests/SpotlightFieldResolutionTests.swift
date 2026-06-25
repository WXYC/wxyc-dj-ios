//
//  SpotlightFieldResolutionTests.swift
//  WXYCDJTests
//
//  Device-gated probe (issue #32): measures which CSSearchableItemAttributeSet
//  fields Core Spotlight actually resolves a free-text query against on the iOS
//  18.4+ floor, and confirms a real CatalogRow surfaces by artist / label / call
//  number. Turns the "keywords may go unsearched on iOS 17+" folklore into measured
//  fact on the real target OS. Gated by WXYC_SPOTLIGHT_FIELD_RESOLUTION; run on a
//  PHYSICAL DEVICE — the Simulator's Spotlight query path is unreliable (same
//  caveat as the deep-link surface, #19/#32) and proves nothing.
//
//  Created by Jake on 06/25/26.
//  Copyright © 2026 WXYC. All rights reserved.
//

import CoreSpotlight
import Foundation
import Testing
import WXYCAPI

/// Measures Core Spotlight's free-text field matching on the deployment floor.
/// Gated off by default — only runs when `WXYC_SPOTLIGHT_FIELD_RESOLUTION` is set —
/// so the CI Simulator run (where Spotlight querying is flaky) never depends on
/// real-daemon behavior, while a maintainer opts in on device. `.serialized`
/// because the Spotlight index is a shared, stateful resource and these tests both
/// index into `CSSearchableIndex.default()`.
///
/// Why `.default()` and `CSSearchQuery`, not the production named index: field
/// matching is a property of Spotlight's *matcher*, not of the index name (issue
/// #32), so a result measured here transfers to the client-owned
/// `org.wxyc.dj.catalog` index. `CSSearchQuery`'s long-lived `init(queryString:
/// attributes:)` + `foundItemsHandler`/`completionHandler` is the stable callback
/// API. The named-index *home-screen* surfacing (what the system UI matcher drives)
/// remains a manual device confirmation — see README.
@Suite(
    "Spotlight field resolution",
    .serialized,
    .enabled(
        if: ProcessInfo.processInfo.environment["WXYC_SPOTLIGHT_FIELD_RESOLUTION"] != nil,
        "Set WXYC_SPOTLIGHT_FIELD_RESOLUTION=1 and run on a physical device; skipped in CI (Simulator Spotlight querying is unreliable)."
    )
)
struct SpotlightFieldResolutionTests {
    /// The five attributes the mapping (`CatalogSpotlight.searchableItem(for:)`)
    /// touches, probed one at a time to see which the matcher resolves.
    enum ProbeField: String, CaseIterable {
        case title, displayName, textContent, contentDescription, keywords
    }

    static let probeDomain = "org.wxyc.dj.fieldprobe"
    /// A `displayName` that contains no probe nonce — set on every item so Core
    /// Spotlight never rejects one as invalid (`CSIndexError -1001`), without
    /// polluting any nonce query (except the `displayName` probe, where the nonce
    /// *is* the displayName).
    static let displayNameSentinel = "WXYC Field Probe Item"

    /// A distinctive, per-field nonce — distinct full strings so a query for one
    /// field's nonce can never substring-match another field's item.
    static func nonce(for field: ProbeField) -> String {
        "wxycprobe\(field.rawValue.lowercased())nonce"
    }

    /// A probe item carrying `nonce` in **exactly** `field`. `displayName` is always
    /// set (to dodge `-1001`); for the `displayName` case the nonce doubles as it.
    static func probeItem(field: ProbeField, nonce: String) -> CSSearchableItem {
        let attributes = CSSearchableItemAttributeSet(contentType: .content)
        attributes.displayName = field == .displayName ? nonce : displayNameSentinel
        switch field {
        case .title: attributes.title = nonce
        case .displayName: break   // already the nonce, above
        case .textContent: attributes.textContent = nonce
        case .contentDescription: attributes.contentDescription = nonce
        case .keywords: attributes.keywords = [nonce]
        }
        return CSSearchableItem(
            uniqueIdentifier: "\(probeDomain).\(field.rawValue)",
            domainIdentifier: probeDomain,
            attributeSet: attributes
        )
    }

    /// Index a nonce in each field in isolation, query each nonce, and record which
    /// fields the matcher resolves — the evidence the issue's acceptance wants. Hard
    /// asserts only the fields the mapping now *relies on* (`title`/`displayName`/
    /// `textContent`); `keywords`/`contentDescription` are measured-and-printed, not
    /// asserted, since their behavior is the unknown under test.
    @Test func measureWhichFieldsResolveAFreeTextQuery() async throws {
        let fields = ProbeField.allCases
        let items = fields.map { Self.probeItem(field: $0, nonce: Self.nonce(for: $0)) }
        try await withIndexedProbeItems(items) {
            var resolved: [ProbeField: Bool] = [:]
            for field in fields {
                resolved[field] = try await resolves(
                    term: Self.nonce(for: field),
                    expectedIdentifier: "\(Self.probeDomain).\(field.rawValue)"
                )
            }

            // The recorded measurement (issue #32 acceptance: "measured and recorded").
            let summary = fields
                .map { "\($0.rawValue)=\(resolved[$0] == true ? "YES" : "no")" }
                .joined(separator: " ")
            print("SPOTLIGHT FIELD RESOLUTION [\(Self.osVersion)]: \(summary)")

            #expect(resolved[.title] == true, "title is the canonical reliably-matched field.")
            #expect(resolved[.displayName] == true, "displayName is the canonical reliably-matched field.")
            #expect(
                resolved[.textContent] == true,
                "textContent must resolve — issue #32 routes artist/label/call-number recall through it."
            )
        }
    }

    /// The end-to-end acceptance in automated form: a real `CatalogRow` indexed via
    /// the production mapping must resolve a free-text query for its **artist**,
    /// **label**, and **call number** (the home-screen named-index surfacing is the
    /// manual device step the README documents).
    @Test func catalogRowResolvesByArtistLabelAndCallNumber() async throws {
        let row = CatalogRow(
            id: 90_032, artistName: "Juana Molina", albumTitle: "DOGA",
            codeLetters: "MOL", codeNumber: 12, codeArtistNumber: 1,
            label: "Sonamos", genreName: "Rock", formatName: "CD",
            onStreaming: true, plays: 34, artworkURL: nil,
            rotationBin: nil, rotationKillDate: nil
        )
        let item = CatalogSpotlight.searchableItem(for: row)
        let identifier = item.uniqueIdentifier
        try await withIndexedProbeItems([item]) {
            let artistResolved = try await resolves(term: row.artistName, expectedIdentifier: identifier)
            let labelResolved = try await resolves(term: "Sonamos", expectedIdentifier: identifier)
            let callNumberResolved = try await resolves(term: row.callNumber, expectedIdentifier: identifier)

            print(
                "SPOTLIGHT CATALOG ROW RESOLUTION [\(Self.osVersion)]: "
                    + "artist=\(artistResolved) label=\(labelResolved) "
                    + "callNumber=\(callNumberResolved) (\(row.callNumber))"
            )

            #expect(artistResolved, "An indexed artist name must resolve the album (issue #32 acceptance).")
            #expect(labelResolved, "An indexed label must resolve the album (issue #32 acceptance).")
            #expect(callNumberResolved, "An indexed call number must resolve the album (issue #32 acceptance).")
        }
    }

    /// Index `items` into `CSSearchableIndex.default()`, run `body`, then **always**
    /// remove them — even if `body` throws — so a probe never strands a synthetic item
    /// in the device's shared, user-visible Spotlight index (where the catalog-row
    /// probe carries the production `album.<id>` identifier, a tap on a leaked one
    /// would deep-link to a missing album). `.default()` — not a throwaway named index
    /// like `SpotlightClientStateToleranceTests` uses — is required because
    /// `CSSearchQuery` only reaches the system index (issue #32). The delete is
    /// best-effort (`try?`): a daemon that drops it leaves a self-healing orphan under
    /// a fixed identifier, overwritten on the next run.
    private func withIndexedProbeItems(
        _ items: [CSSearchableItem],
        _ body: () async throws -> Void
    ) async throws {
        let index = CSSearchableIndex.default()
        let identifiers = items.map(\.uniqueIdentifier)
        try await index.indexSearchableItems(items)
        do {
            try await body()
        } catch {
            try? await index.deleteSearchableItems(withIdentifiers: identifiers)
            throw error
        }
        try? await index.deleteSearchableItems(withIdentifiers: identifiers)
    }

    // MARK: - Query plumbing

    /// Poll the matcher for `term` until `expectedIdentifier` appears, to absorb the
    /// brief indexing latency between `indexSearchableItems` returning and the item
    /// becoming queryable. 10 attempts × 100 ms ≈ 1 s ceiling. A genuine query error
    /// is **rethrown**, not retried or collapsed to `false`: an empty result (the item
    /// isn't queryable yet) is the retryable case, whereas a thrown `CSSearchQuery`
    /// error is a probe malfunction the measurement must surface as itself — otherwise
    /// a daemon/entitlement failure masquerades as "this field doesn't resolve" and a
    /// hard `#expect` blames the mapping instead of the query plumbing.
    private func resolves(
        term: String,
        expectedIdentifier: String,
        attempts: Int = 10,
        delay: Duration = .milliseconds(100)
    ) async throws -> Bool {
        for _ in 0..<attempts {
            let ids = try await Self.matchingIdentifiers(forTerm: term)
            if ids.contains(expectedIdentifier) { return true }
            try? await Task.sleep(for: delay)
        }
        return false
    }

    /// Run a Spotlight free-text query and return the matched items' identifiers.
    /// **Word-based** match (`w`), case- and diacritic-insensitive (`cd`): the term's
    /// tokens are matched as word prefixes against any searchable attribute (`**`).
    /// Word-based rather than raw substring so a multi-token term survives Spotlight's
    /// tokenization — "Juana Molina" and the call number "MOL 1/12" (space + slash)
    /// match the indexed words instead of needing the literal substring to appear
    /// unsplit. If a device run still returns nothing the matcher syntax is the only
    /// fragile part of this probe — try the `CSUserQuery` natural-language API or
    /// adjust the modifiers.
    private static func matchingIdentifiers(forTerm term: String) async throws -> [String] {
        let escaped = term
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        let queryString = "**==\"\(escaped)*\"cdw"

        let collector = IdentifierCollector()
        let query = CSSearchQuery(queryString: queryString, attributes: [])
        query.foundItemsHandler = { items in collector.add(items) }
        let identifiers: [String] = try await withCheckedThrowingContinuation { continuation in
            query.completionHandler = { error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume(returning: collector.snapshot())
                }
            }
            query.start()
        }
        // Keep `query` alive across the await. CSSearchQuery, like NSMetadataQuery,
        // must outlive its async completion; `start()` was its last use, so ARC could
        // otherwise release it at the suspension point above and the daemon would drop
        // the query — `completionHandler` would never fire and the continuation would
        // hang forever (the suite sets no time limit). `withExtendedLifetime` anchors
        // it past the await without touching the (already-completed) query.
        withExtendedLifetime(query) {}
        return identifiers
    }

    private static var osVersion: String {
        let v = ProcessInfo.processInfo.operatingSystemVersion
        return "iOS \(v.majorVersion).\(v.minorVersion).\(v.patchVersion)"
    }

    /// Thread-safe accumulator for the query's `foundItemsHandler`, which the daemon
    /// may invoke repeatedly off the calling thread. Extracts only the `Sendable`
    /// identifier so no non-`Sendable` `CSSearchableItem` escapes the closure.
    private final class IdentifierCollector: @unchecked Sendable {
        private let lock = NSLock()
        private var identifiers: [String] = []

        func add(_ items: [CSSearchableItem]) {
            let mapped = items.map(\.uniqueIdentifier)
            lock.lock()
            identifiers.append(contentsOf: mapped)
            lock.unlock()
        }

        func snapshot() -> [String] {
            lock.lock()
            defer { lock.unlock() }
            return identifiers
        }
    }
}
