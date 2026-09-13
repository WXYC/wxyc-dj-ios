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
//  as an implementation detail — we poll until the property under assertion
//  settles rather than asserting against the wall clock. Poll the property the
//  test actually asserts, not a proxy for it: `state` and `digitalAudioIDs` are
//  published at two different points in `performSearch` (issue #159).
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
            // The badge set, not `state`. `performSearch` publishes `state`
            // before it awaits the clone read, so a settled state leaves
            // `digitalAudioIDs` still suspended (issue #159).
            try await Self.waitUntil("the badge set to hydrate from the clone") {
                viewModel.digitalAudioIDs == [100]
            }

            #expect(viewModel.digitalAudioIDs == [100])
        }
    }

    /// The clone answering "no digital audio" must leave the badge set empty —
    /// and that emptiness has to be *earned*. `digitalAudioIDs` starts empty, so
    /// asserting it straight after a single search proves nothing: the value
    /// reads identically whether hydration ran and wrote nothing or never ran at
    /// all — and `waitForSettle` returns while the clone read is still
    /// suspended (issue #159), so it was routinely the latter.
    ///
    /// So seed the set first from a clone that says *yes*, then flip the clone's
    /// answer to *no* and search again. That gives the wait a real edge —
    /// `[100]` → `[]` — which only a hydration that ran to completion can
    /// produce. Delete the `digitalAudioIDs` write from `hydrateDigitalAudioIDs`
    /// and this now fails on its own deadline instead of passing on the initial
    /// value.
    @Test func settledSearchLeavesDigitalAudioIDsEmptyWhenCloneSaysNo() async throws {
        let (client, session) = try await SignedInClient.make()
        defer { Self.removeStore() }
        do {
            let store = try await Self.makeStore(rows: [Self.juanaCatalogRow.withDigitalAudio(true)])
            let viewModel = Self.makeViewModel(client, store: store)
            for _ in 0..<2 {
                session.enqueue(StubRequestSession.Stub(
                    statusCode: 200,
                    body: Data(Fixtures.juanaMolinaSearchResultsJSON.utf8)
                ))
            }

            viewModel.query = "ju"
            try await Self.waitUntil("the clone's yes to seed the badge set") {
                viewModel.digitalAudioIDs == [100]
            }

            // Same row, `hasDigitalAudio` back to its default false.
            try await store.replace(rows: [Self.juanaCatalogRow], lastModified: nil)
            viewModel.query = "jua"
            try await Self.waitUntil("the clone's no to clear the badge set") {
                viewModel.digitalAudioIDs.isEmpty
            }

            #expect(viewModel.digitalAudioIDs.isEmpty)
        }
    }

    /// A debounce-superseded search must not hydrate `digitalAudioIDs` for
    /// results the DJ never saw. Both requests resolve to the same fixture
    /// body, so the final `digitalAudioIDs` value would look identical either
    /// way -- what this asserts is the **count** of `rows(ids:)` calls, exactly
    /// one (the surviving search), not two.
    ///
    /// Note what that does and does not prove: the count is enforced by
    /// `performSearch`'s *pre-existing* `Task.isCancelled` check, which returns
    /// before `hydrateDigitalAudioIDs` is ever reached. The guard *inside*
    /// `hydrateDigitalAudioIDs` — after the store await — is covered by
    /// `cancellationDuringTheCloneReadLeavesBadgesUntouched` below instead.
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
        // The badge set, not `state` — see `waitForSettle`'s doc. Waiting on
        // `state` here is what made this test flake under full-suite load: it
        // returned while the surviving search's clone read was still suspended,
        // and the assertion below raced that continuation (issue #159).
        try await Self.waitUntil("the surviving search to hydrate the badge set") {
            viewModel.digitalAudioIDs == [100]
        }

        #expect(store.rowsCallCount == 1)
        #expect(viewModel.digitalAudioIDs == [100])
    }

    /// Cancellation landing *during* the clone read — the window
    /// `hydrateDigitalAudioIDs`'s own post-await `Task.isCancelled` covers, and
    /// the one `supersededSearchDoesNotHydrateDigitalAudioIDs` cannot reach
    /// (there the outer check in `performSearch` returns first).
    ///
    /// The superseding keystroke drops *below* `minQueryLength`, so the search
    /// is abandoned rather than replaced and no second search runs to write
    /// `digitalAudioIDs` for us. `onQueryChanged`'s abandonment arm clears
    /// `results` and `state` but deliberately never touches `digitalAudioIDs`,
    /// so whatever the badge set holds at the end is whatever the cancelled
    /// task left it holding.
    ///
    /// Which is why this asserts `[100]` rather than `.isEmpty` (issue #159).
    /// A test that asserts *nothing happened* has no edge of its own to wait
    /// on, so it borrows two:
    ///
    /// - A **seed**. A first search, run to completion against a clone that
    ///   says *yes*, leaves `digitalAudioIDs == [100]`; the clone then flips to
    ///   *no*, so a cancelled task that ignored the guard would write `[]` —
    ///   distinguishable from the seed. The old `.isEmpty` assertion was not:
    ///   it read the same whether the guard fired or the hydration write had
    ///   been deleted outright, and it passed in both cases.
    /// - A **completion signal**. `rowsReturnCount` ticks when a parked read
    ///   hands its rows back. `rowsCallCount` ticks on *entry* and is already
    ///   nonzero by the time `waitForFirstRowsCall()` returns, so it cannot say
    ///   whether the released read ever resumed.
    ///
    /// Delete the `if Task.isCancelled { return }` at the end of
    /// `hydrateDigitalAudioIDs` and the cancelled task clears the seed.
    @Test func cancellationDuringTheCloneReadLeavesBadgesUntouched() async throws {
        let (client, session) = try await SignedInClient.make()
        for _ in 0..<2 {
            session.enqueue(StubRequestSession.Stub(
                statusCode: 200,
                body: Data(Fixtures.juanaMolinaSearchResultsJSON.utf8)
            ))
        }
        let store = CountingCatalogStore(rows: [Self.juanaCatalogRow.withDigitalAudio(true)])
        let viewModel = Self.makeViewModel(client, store: store)

        // Seed: one search that runs all the way through, so the badge set
        // holds a value hydration demonstrably *can* write.
        viewModel.query = "ju"
        try await Self.waitUntil("the seeding search to hydrate the badge set") {
            viewModel.digitalAudioIDs == [100]
        }

        // Flip the clone's answer, so an unguarded cancelled write would clear
        // the seed rather than rewrite it, and park the next read.
        store.replace(rows: [Self.juanaCatalogRow], lastModified: nil)
        store.startBlocking()

        viewModel.query = "jua"
        // Park until the clone read is genuinely in flight — the request has
        // already settled by this point, so `performSearch`'s own cancellation
        // check is behind us.
        await store.waitForFirstRowsCall()

        // Below `minQueryLength`: cancels the in-flight task and starts no
        // replacement, leaving the assertion to observe only the guard.
        viewModel.query = "j"
        store.releaseRows()

        // `waitForSettle` is useless here: the abandonment arm sets `.idle`
        // synchronously, so it returns before the cancelled task has resumed.
        // Wait on the read handing its rows back instead.
        try await Self.waitUntil("the parked clone read to return") {
            store.rowsReturnCount == 2
        }
        // One MainActor hop still separates that return from the guard: the
        // `await` in `hydrateDigitalAudioIDs` resumes on the MainActor to run
        // `Task.isCancelled` and, if it were deleted, to write `[]` on the next
        // line. A negative assertion cannot be waited on, only drained for —
        // but the drain is now a bounded settle behind a real edge rather than
        // a wall-clock bet on the whole release propagating.
        for _ in 0..<10 { await Task.yield() }
        try await Task.sleep(for: .milliseconds(50))

        #expect(store.rowsCallCount == 2)
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

    /// Poll until `condition` holds, or `timeout` elapses.
    ///
    /// **A timeout is a failure, not a fall-through.** The predecessor of this
    /// helper returned quietly when its deadline passed, which is the mechanism
    /// that let a wait which never settled read exactly like one that did
    /// (issue #159) — the assertion after it then raced the thing it had been
    /// waiting for, and passed by margin until the machine was busy enough that
    /// it didn't. Recording the `Issue` at the *caller's* source location puts
    /// the failure on the line where the wait was written rather than in here.
    ///
    /// Polling rather than awaiting because `SearchViewModel` publishes no
    /// completion edge; pass the predicate over the property the test actually
    /// asserts, not a proxy for it (see ``waitForSettle(_:sourceLocation:)``).
    private static func waitUntil(
        _ what: String,
        timeout: Duration = .seconds(2),
        sourceLocation: SourceLocation = #_sourceLocation,
        _ condition: () -> Bool
    ) async throws {
        let deadline = ContinuousClock.now + timeout
        while !condition() {
            guard ContinuousClock.now < deadline else {
                Issue.record(
                    "timed out after \(timeout) waiting for \(what)",
                    sourceLocation: sourceLocation
                )
                return
            }
            try await Task.sleep(for: .milliseconds(25))
        }
    }

    /// Poll until the view model leaves `.searching`.
    ///
    /// This is the *front* half of a search and nothing more. `performSearch`
    /// publishes `state` — and captures the analytics event — **before** it
    /// awaits `hydrateDigitalAudioIDs`, so a settled state means results are on
    /// screen while the badge set may still be suspended on the clone read. A
    /// test that asserts on `digitalAudioIDs` must wait on `digitalAudioIDs`
    /// (issue #159); the call sites left here assert on `state`, `results`,
    /// `source`, or the analytics spy, all of which this genuinely covers.
    private static func waitForSettle(
        _ viewModel: SearchViewModel,
        sourceLocation: SourceLocation = #_sourceLocation
    ) async throws {
        try await waitUntil("the search to leave .searching", sourceLocation: sourceLocation) {
            viewModel.state != .searching
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
///
/// Entries and returns are counted separately — while a blocking read is parked
/// the two differ, and a test that has to know a *cancelled* read resumed needs
/// the return (issue #159).
private final class CountingCatalogStore: CatalogStore {
    private struct State {
        var rows: [Int: CatalogRow]
        /// `rows(ids:)` entries.
        var rowsCalls = 0
        /// `rows(ids:)` returns — ticked after the blocking gate, if any.
        var rowsReturns = 0
        /// When true, `rows(ids:)` parks until `releaseRows()` — the store
        /// analogue of `BlockingRequestSession`, so a test can cancel the
        /// calling task while the clone read is genuinely in flight.
        var blocking = false
        var released = false
        var firstCallArrived = false
        var blocked: [CheckedContinuation<Void, Never>] = []
        var firstCallWaiters: [CheckedContinuation<Void, Never>] = []
    }

    private let state: OSAllocatedUnfairLock<State>

    init(rows: [CatalogRow]) {
        state = OSAllocatedUnfairLock(
            initialState: State(rows: Dictionary(uniqueKeysWithValues: rows.map { ($0.id, $0) }))
        )
    }

    var rowsCallCount: Int { state.withLock { $0.rowsCalls } }
    /// `rows(ids:)` calls that have **returned**, as opposed to merely been
    /// entered. The only edge a test has for "the parked clone read resumed".
    var rowsReturnCount: Int { state.withLock { $0.rowsReturns } }

    func row(id: Int) -> CatalogRow? { state.withLock { $0.rows[id] } }
    func count() -> Int { state.withLock { $0.rows.count } }
    func lastModified() -> String? { nil }
    func replace(rows: [CatalogRow], lastModified: String?) {
        state.withLock { $0.rows = Dictionary(uniqueKeysWithValues: rows.map { ($0.id, $0) }) }
    }
    func search(query: String, limit: Int) -> [CatalogRow] { [] }

    func rows(ids: [Int]) async -> [Int: CatalogRow] {
        let (result, firstWaiters): ([Int: CatalogRow], [CheckedContinuation<Void, Never>]) = state.withLock { st in
            st.rowsCalls += 1
            var result: [Int: CatalogRow] = [:]
            for id in ids { if let row = st.rows[id] { result[id] = row } }
            guard st.blocking, !st.firstCallArrived else { return (result, []) }
            st.firstCallArrived = true
            defer { st.firstCallWaiters = [] }
            return (result, st.firstCallWaiters)
        }
        for continuation in firstWaiters { continuation.resume() }

        if state.withLock({ $0.blocking }) {
            await withCheckedContinuation { continuation in
                let resumeNow: Bool = state.withLock { st in
                    if st.released { return true }
                    st.blocked.append(continuation)
                    return false
                }
                if resumeNow { continuation.resume() }
            }
        }
        state.withLock { $0.rowsReturns += 1 }
        return result
    }

    // MARK: - Optional blocking gate

    /// Arm the blocking gate. Deliberately not an `init` parameter: a test that
    /// needs the badge set seeded by a *completed* read before it parks the next
    /// one would otherwise park the seeding read too. Resets the gate's one-shot
    /// bookkeeping so `waitForFirstRowsCall()` refers to the read this arms for.
    func startBlocking() {
        state.withLock { st in
            st.blocking = true
            st.released = false
            st.firstCallArrived = false
        }
    }

    /// Suspends until at least one `rows(ids:)` call has been entered since the
    /// gate was armed. Only meaningful after ``startBlocking()``.
    func waitForFirstRowsCall() async {
        await withCheckedContinuation { continuation in
            let resumeNow: Bool = state.withLock { st in
                if st.firstCallArrived { return true }
                st.firstCallWaiters.append(continuation)
                return false
            }
            if resumeNow { continuation.resume() }
        }
    }

    /// Let every parked (and future) `rows(ids:)` call return.
    func releaseRows() {
        let toResume: [CheckedContinuation<Void, Never>] = state.withLock { st in
            st.released = true
            defer { st.blocked = [] }
            return st.blocked
        }
        for continuation in toResume { continuation.resume() }
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
