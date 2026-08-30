//
//  SearchViewModelTests.swift
//  WXYCDJTests
//
//  Pins SearchViewModel's outward state machine: short / empty queries stay
//  idle, a hit transitions to .results, an empty response to .empty, and a
//  follow-up keystroke that shortens the query below the minimum length cancels
//  the in-flight task and clears results without hitting the network. Offline
//  (or on a failed request) the view model serves the on-device clone and
//  exposes `.local` as the source (issue #58). The debounce *timing* is treated
//  as an implementation detail — we poll the state until it settles rather than
//  asserting against the wall clock.
//
//  Created by Jake on 5/20/26.
//  Copyright © 2026 WXYC. All rights reserved.
//

import Foundation
import os
import Testing
@testable import WXYCAPI
@testable import WXYCDJ

@Suite("SearchViewModel", .serialized)
@MainActor
struct SearchViewModelTests {
    /// Build a view model whose LibrarySearch is online by default with no local
    /// clone — the server-path behavior the legacy tests assert. Pass a `store`
    /// and `online: false` to exercise the offline fallback.
    private static func makeViewModel(
        _ client: APIClient,
        store: (any CatalogStore)? = nil,
        online: Bool = true,
        analytics: any Analytics = NoOpAnalytics()
    ) -> SearchViewModel {
        let search = LibrarySearch(
            api: client,
            catalogStore: store,
            connectivity: ConnectivityMonitor(initiallyOnline: online)
        )
        return SearchViewModel(search: search, api: client, catalogStore: store, analytics: analytics)
    }

    @Test func emptyQueryStaysIdleAndIssuesNoRequest() async throws {
        let (client, session) = try await SignedInClient.make()
        let viewModel = Self.makeViewModel(client)
        let baseline = session.recordedRequests.count

        viewModel.query = ""
        try await Self.waitBriefly()

        #expect(viewModel.state == .idle)
        #expect(viewModel.results.isEmpty)
        #expect(session.recordedRequests.count == baseline)
    }

    @Test func singleCharQueryStaysIdleAndIssuesNoRequest() async throws {
        let (client, session) = try await SignedInClient.make()
        let viewModel = Self.makeViewModel(client)
        let baseline = session.recordedRequests.count

        viewModel.query = "j"
        try await Self.waitBriefly()

        #expect(viewModel.state == .idle)
        #expect(viewModel.results.isEmpty)
        #expect(session.recordedRequests.count == baseline)
    }

    @Test func hitTransitionsToResultsState() async throws {
        let (client, session) = try await SignedInClient.make()
        let viewModel = Self.makeViewModel(client)
        session.enqueue(StubRequestSession.Stub(
            statusCode: 200,
            body: Data(Fixtures.juanaMolinaSearchResultsJSON.utf8)
        ))

        viewModel.query = "ju"
        try await Self.waitForSettle(viewModel)

        #expect(viewModel.state == .results)
        #expect(viewModel.source == .server)
        #expect(viewModel.results.count == 1)
        #expect(viewModel.results.first?.artistName == "Juana Molina")
    }

    // MARK: - Issue #136: digital-audio badge hydration

    @Test func settledSearchHydratesDigitalAudioIDsFromOneBatchRead() async throws {
        let (client, session) = try await SignedInClient.make()
        defer { Self.removeStore() }
        do {
            let store = try await Self.makeStore(rows: [
                Self.juanaCatalogRow.withDigitalAudio(true),
            ])
            let viewModel = Self.makeViewModel(client, store: store)
            session.enqueue(StubRequestSession.Stub(
                statusCode: 200,
                body: Data(Fixtures.juanaMolinaSearchResultsJSON.utf8)
            ))

            viewModel.query = "ju"
            try await Self.waitForSettle(viewModel)

            #expect(viewModel.digitalAudioIDs == [100])
        }
    }

    @Test func settledSearchLeavesDigitalAudioIDsEmptyWhenCloneSaysNo() async throws {
        let (client, session) = try await SignedInClient.make()
        defer { Self.removeStore() }
        do {
            let store = try await Self.makeStore(rows: [Self.juanaCatalogRow])
            let viewModel = Self.makeViewModel(client, store: store)
            session.enqueue(StubRequestSession.Stub(
                statusCode: 200,
                body: Data(Fixtures.juanaMolinaSearchResultsJSON.utf8)
            ))

            viewModel.query = "ju"
            try await Self.waitForSettle(viewModel)

            #expect(viewModel.digitalAudioIDs.isEmpty)
        }
    }

    /// A debounce-superseded search must not hydrate `digitalAudioIDs` for
    /// results the DJ never saw — the same post-await `Task.isCancelled` guard
    /// `performSearch` already applies to `results`/`state`/analytics, mirrored
    /// from `searchSupersededMidFlightCapturesOnlyTheServedOne`. Both requests
    /// resolve to the same fixture body, so the final `digitalAudioIDs` value
    /// would look identical whether or not the guard fired -- what actually
    /// proves the guard is the **count** of `rows(ids:)` calls, exactly one
    /// (the surviving search), not two (one per request).
    @Test func supersededSearchDoesNotHydrateDigitalAudioIDs() async throws {
        let (client, blocking) = try await SignedInClient.makeBlocking(
            responseBody: Data(Fixtures.juanaMolinaSearchResultsJSON.utf8)
        )
        let store = CountingCatalogStore(rows: [Self.juanaCatalogRow.withDigitalAudio(true)])
        let viewModel = Self.makeViewModel(client, store: store)

        viewModel.query = "ju"
        // Park until the first search is genuinely on the wire.
        await blocking.waitForFirstRequest()
        // A follow-up keystroke cancels that in-flight task and starts a new
        // search. Still >= minQueryLength, so this is a supersession, not an
        // abandonment.
        viewModel.query = "jua"
        // Let the first (now-cancelled) request resume and the second run.
        blocking.release()
        try await Self.waitForSettle(viewModel)

        #expect(store.rowsCallCount == 1)
        #expect(viewModel.digitalAudioIDs == [100])
    }

    @Test func emptyResponseTransitionsToEmptyState() async throws {
        let (client, session) = try await SignedInClient.make()
        let viewModel = Self.makeViewModel(client)
        session.enqueue(StubRequestSession.Stub(statusCode: 200, body: Data("[]".utf8)))

        viewModel.query = "zzz"
        try await Self.waitForSettle(viewModel)

        #expect(viewModel.state == .empty)
        #expect(viewModel.results.isEmpty)
    }

    @Test func serverErrorWithNoLocalCloneTransitionsToEmpty() async throws {
        // A failed online request now falls back to local instead of erroring;
        // with no clone the fallback is empty (no red banner, no manual retry).
        let (client, session) = try await SignedInClient.make()
        let viewModel = Self.makeViewModel(client)
        session.enqueue(StubRequestSession.Stub(statusCode: 500, body: Data(#"{"error":"boom"}"#.utf8)))

        viewModel.query = "ju"
        try await Self.waitForSettle(viewModel)

        #expect(viewModel.state == .empty)
        #expect(viewModel.source == .local)
        #expect(viewModel.results.isEmpty)
    }

    @Test func offlineServesLocalCloneAndExposesLocalSource() async throws {
        let (client, _) = try await SignedInClient.make()
        defer { Self.removeStore() }
        // Confine the store + view model to an inner scope so the SQLite
        // connection is released (and closed) before the `defer` unlinks the
        // file — otherwise SQLite logs a "vnode unlinked while in use" warning.
        do {
            let store = try await Self.makeStore(rows: [Self.juanaCatalogRow])
            let viewModel = Self.makeViewModel(client, store: store, online: false)

            viewModel.query = "ju"
            try await Self.waitForSettle(viewModel)

            #expect(viewModel.state == .results)
            #expect(viewModel.source == .local)
            #expect(viewModel.results.map(\.id) == [100])
        }
    }

    @Test func addToBinForwardsFirstMatchedTrackTitle() async throws {
        let (client, session) = try await SignedInClient.make()
        let viewModel = Self.makeViewModel(client)
        let row = try AlbumSearchResult.fixture(matchedTrackTitles: ["In a Sentimental Mood"])
        session.enqueue(StubRequestSession.Stub(
            statusCode: 201,
            body: Data(Fixtures.addToBinResponseJSON.utf8)
        ))

        let added = await viewModel.addToBin(row)

        #expect(added)
        let posted = try #require(session.recordedRequests.last)
        #expect(posted.httpMethod == "POST")
        let body = try #require(posted.httpBody)
        let decoded = try JSONCoders.decoder.decode(AddToBinRequest.self, from: body)
        #expect(decoded.albumId == row.id)
        #expect(decoded.trackTitle == "In a Sentimental Mood")
    }

    @Test func addToBinOmitsTrackTitleWhenNotTrackMatched() async throws {
        let (client, session) = try await SignedInClient.make()
        let viewModel = Self.makeViewModel(client)
        let row = try AlbumSearchResult.fixture(matchedTrackTitles: [])
        session.enqueue(StubRequestSession.Stub(
            statusCode: 201,
            body: Data(Fixtures.addToBinResponseJSON.utf8)
        ))

        let added = await viewModel.addToBin(row)

        #expect(added)
        let posted = try #require(session.recordedRequests.last)
        let body = try #require(posted.httpBody)
        let decoded = try JSONCoders.decoder.decode(AddToBinRequest.self, from: body)
        #expect(decoded.trackTitle == nil)
    }

    // MARK: - Issue #108: search analytics

    @Test func settledSearchRecordsSearchPerformed() async throws {
        let (client, session) = try await SignedInClient.make()
        let analytics = SpyAnalytics()
        let viewModel = Self.makeViewModel(client, analytics: analytics)
        session.enqueue(StubRequestSession.Stub(
            statusCode: 200,
            body: Data(Fixtures.juanaMolinaSearchResultsJSON.utf8)
        ))

        viewModel.query = "ju"
        try await Self.waitForSettle(viewModel)

        #expect(analytics.captures.count == 1)
        let capture = try #require(analytics.captures.first)
        #expect(capture.name == "search_performed")
        #expect(capture.properties["source"] == .enumString(SearchSource.server))
        #expect(capture.properties["result_count"] == .int(1))
        #expect(capture.properties["query_length"] == .int(2))
    }

    @Test func offlineSearchRecordsLocalSource() async throws {
        let (client, _) = try await SignedInClient.make()
        defer { Self.removeStore() }
        // Inner scope for the same reason as
        // `offlineServesLocalCloneAndExposesLocalSource` above: release the
        // SQLite connection before the `defer` unlinks the file.
        do {
            let store = try await Self.makeStore(rows: [Self.juanaCatalogRow])
            let analytics = SpyAnalytics()
            let viewModel = Self.makeViewModel(client, store: store, online: false, analytics: analytics)

            viewModel.query = "ju"
            try await Self.waitForSettle(viewModel)

            let capture = try #require(analytics.captures.first)
            #expect(capture.properties["source"] == .enumString(SearchSource.local))
            #expect(capture.properties["result_count"] == .int(1))
        }
    }

    /// A search superseded **mid-flight** captures nothing (issue #108): the DJ
    /// never saw those results, so it isn't a served search.
    ///
    /// This drives the case that actually exercises the guard. `performSearch(_:)`
    /// checks `Task.isCancelled` *after* `LibrarySearch.search(query:)` returns
    /// and *before* capturing, so the only way to reach that check is to have a
    /// request genuinely in flight when the next keystroke lands — hence the
    /// `BlockingRequestSession`. Both queries clear `minQueryLength`, so the
    /// earlier "drop below 2 characters" version of this test never entered
    /// `performSearch` at all and would still have passed with the guard
    /// deleted. Here, deleting it yields two captures instead of one.
    @Test func searchSupersededMidFlightCapturesOnlyTheServedOne() async throws {
        let (client, blocking) = try await SignedInClient.makeBlocking(
            responseBody: Data(Fixtures.juanaMolinaSearchResultsJSON.utf8)
        )
        let analytics = SpyAnalytics()
        let viewModel = Self.makeViewModel(client, analytics: analytics)

        viewModel.query = "ju"
        // Park until the first search is genuinely on the wire.
        await blocking.waitForFirstRequest()
        // A follow-up keystroke cancels that in-flight task and starts a new
        // search. Still >= minQueryLength, so this is a supersession, not an
        // abandonment.
        viewModel.query = "jua"
        // Let the first (now-cancelled) request resume and the second run.
        blocking.release()
        try await Self.waitForSettle(viewModel)

        #expect(analytics.captures.count == 1)
        let capture = try #require(analytics.captures.first)
        #expect(capture.name == "search_performed")
        // The *served* query is the 3-character one, proving the survivor is
        // the later search rather than the superseded one.
        #expect(capture.properties["query_length"] == .int(3))
    }

    /// The abandonment case: dropping below `minQueryLength` cancels the pending
    /// debounce before it ever issues a request, so there is nothing to serve
    /// and nothing to capture.
    @Test func searchAbandonedBeforeItIssuesCapturesNothing() async throws {
        let (client, session) = try await SignedInClient.make()
        let analytics = SpyAnalytics()
        let viewModel = Self.makeViewModel(client, analytics: analytics)
        session.enqueue(StubRequestSession.Stub(
            statusCode: 200,
            body: Data(Fixtures.juanaMolinaSearchResultsJSON.utf8)
        ))

        viewModel.query = "ju"
        viewModel.query = "j"
        try await Self.waitBriefly()

        #expect(analytics.captures.isEmpty)
    }

    @Test func shorteningQueryBelowMinimumCancelsInFlightSearch() async throws {
        let (client, session) = try await SignedInClient.make()
        let viewModel = Self.makeViewModel(client)
        let baseline = session.recordedRequests.count

        viewModel.query = "ju"
        #expect(viewModel.state == .searching)

        // Drop below the 2-char minimum before the debounce fires. The pending
        // Task should be cancelled; state resets to .idle; nothing hits the
        // network.
        viewModel.query = "j"
        try await Self.waitBriefly()

        #expect(viewModel.state == .idle)
        #expect(viewModel.results.isEmpty)
        #expect(session.recordedRequests.count == baseline)
    }

    /// Sleep just long enough to be confident the debounce timer would have
    /// fired if it was going to. Used by the "should *not* fire" cases.
    private static func waitBriefly() async throws {
        try await Task.sleep(for: .milliseconds(500))
    }

    /// Poll until the view model leaves .searching, or 2 s elapses.
    private static func waitForSettle(_ viewModel: SearchViewModel) async throws {
        let deadline = Date().addingTimeInterval(2.0)
        while viewModel.state == .searching && Date() < deadline {
            try await Task.sleep(for: .milliseconds(25))
        }
    }

    // MARK: Local-store helpers (offline fallback)

    /// A WXYC-representative catalog row (Juana Molina, id 100) for the offline
    /// fallback test.
    static let juanaCatalogRow = CatalogRow(
        id: 100, artistName: "Juana Molina", albumTitle: "DOGA",
        codeLetters: "MOL", codeNumber: 12, codeArtistNumber: 1,
        label: "Sonamos", genreName: "Rock", formatName: "CD",
        onStreaming: true, plays: 34, artworkURL: nil,
        rotationBin: nil, rotationKillDate: nil
    )

    nonisolated(unsafe) private static var storeURL: URL?

    /// A real SQLiteCatalogStore at a fresh temp path, seeded with `rows` (which
    /// builds the FTS index). The app-test bundle can't see WXYCAPITests' spy, so
    /// the offline path is exercised against the production store.
    private static func makeStore(rows: [CatalogRow]) async throws -> SQLiteCatalogStore {
        let url = FileManager.default.temporaryDirectory
            .appending(path: "search-vm-test-\(UUID().uuidString).sqlite")
        storeURL = url
        let store = try SQLiteCatalogStore(url: url)
        try await store.replace(rows: rows, lastModified: nil)
        return store
    }

    private static func removeStore() {
        guard let url = storeURL else { return }
        let fm = FileManager.default
        try? fm.removeItem(at: url)
        let base = url.path(percentEncoded: false)
        for suffix in ["-journal", "-wal", "-shm"] {
            try? fm.removeItem(at: URL(filePath: base + suffix))
        }
        storeURL = nil
    }
}

/// A `CatalogStore` that counts `rows(ids:)` calls, so a supersession test can
/// assert the guard fired by call count rather than by the (identical either
/// way) final hydrated value. Lock-guarded `Sendable`, matching
/// `WXYCAPITests/Support/SpyCatalogStore.swift`'s shape.
private final class CountingCatalogStore: CatalogStore {
    private let state: OSAllocatedUnfairLock<(rows: [Int: CatalogRow], rowsCalls: Int)>

    init(rows: [CatalogRow]) {
        state = OSAllocatedUnfairLock(initialState: (
            rows: Dictionary(uniqueKeysWithValues: rows.map { ($0.id, $0) }),
            rowsCalls: 0
        ))
    }

    var rowsCallCount: Int { state.withLock { $0.rowsCalls } }

    func row(id: Int) -> CatalogRow? { state.withLock { $0.rows[id] } }
    func count() -> Int { state.withLock { $0.rows.count } }
    func lastModified() -> String? { nil }
    func replace(rows: [CatalogRow], lastModified: String?) {
        state.withLock { $0.rows = Dictionary(uniqueKeysWithValues: rows.map { ($0.id, $0) }) }
    }
    func search(query: String, limit: Int) -> [CatalogRow] { [] }

    func rows(ids: [Int]) -> [Int: CatalogRow] {
        state.withLock { st in
            st.rowsCalls += 1
            var result: [Int: CatalogRow] = [:]
            for id in ids { if let row = st.rows[id] { result[id] = row } }
            return result
        }
    }
}

private extension CatalogRow {
    /// Same row with `hasDigitalAudio` overridden — a test-only convenience
    /// so `juanaCatalogRow` doesn't need a second, near-duplicate literal.
    func withDigitalAudio(_ value: Bool) -> CatalogRow {
        CatalogRow(
            id: id, artistName: artistName, albumTitle: albumTitle,
            codeLetters: codeLetters, codeNumber: codeNumber, codeArtistNumber: codeArtistNumber,
            label: label, genreName: genreName, formatName: formatName,
            onStreaming: onStreaming, plays: plays, artworkURL: artworkURL,
            rotationBin: rotationBin, rotationKillDate: rotationKillDate.day,
            hasDigitalAudio: value
        )
    }
}

// Decode-from-JSON fixture builder. Mirrors the TrackMatchHint.fixture
// helper in TrackMatchBadgeTests — surfacing decode failures as thrown
// errors keeps a bad fixture from crashing the runner.
private extension AlbumSearchResult {
    static func fixture(matchedTrackTitles: [String]) throws -> AlbumSearchResult {
        let hints = matchedTrackTitles.map { """
            { "title": "\($0)", "source": "cta" }
        """ }.joined(separator: ",")
        let payload = """
            {
              "id": 100,
              "album_title": "DOGA",
              "artist_name": "Juana Molina",
              "matched_via": [\(hints)]
            }
            """
        return try JSONCoders.decoder.decode(AlbumSearchResult.self, from: Data(payload.utf8))
    }
}
