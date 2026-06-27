//
//  ConnectivityMonitor.swift
//  WXYCAPI
//
//  App-wide observable online/offline signal, corrected by real request
//  outcomes — not just the OS path. The OS reachability comes through the
//  PathProvider seam; a transport failure or success from APIClient overrides
//  it (last-write-wins). Owned by the composition root like AuthService and read
//  by the offline banner (#56) and the rest of the offline epic (#58–#61).
//
//  Created by Jake on 6/26/26.
//  Copyright © 2026 WXYC. All rights reserved.
//

import Foundation
import Observation

/// Observable online/offline state for the whole app.
///
/// Two signals feed it, with **last-write-wins** precedence across them:
/// - The OS network path (via ``PathProvider``): a `.satisfied` path means
///   online, anything else offline.
/// - Real request outcomes (``noteOutcome(success:)``): a transport failure
///   latches **offline even when the OS path is satisfied** (captive portal,
///   backend down); a success restores online.
///
/// Whichever signal fired most recently wins. A `noteOutcome(success: false)`
/// stays offline until *either* a later successful outcome *or* a fresh
/// satisfied path update arrives.
@MainActor
@Observable
public final class ConnectivityMonitor {
    /// `true` when the app believes it can reach the backend. Starts optimistic
    /// and is corrected on the first path update or request outcome.
    public private(set) var isOnline: Bool

    /// Yields once on every offline→online transition of ``isOnline``
    /// (cause-agnostic: a satisfied path update *or* a successful outcome). The
    /// reconnect edge #61's `BinSyncService` drains to flush queued bin writes;
    /// #56 only vends and tests it.
    ///
    /// Buffered **newest-1**: the documented consumer attaches *after* launch, so
    /// it must wake on the *next* reconnect, not replay the whole app-lifetime
    /// backlog (which would fire one queued-bin flush per historical edge). A
    /// reconnect flush is idempotent, so at-most-one stale wake is harmless; an
    /// unbounded backlog is not. It also bounds the buffer when (as in #56)
    /// nothing is consuming the stream yet.
    public let reconnects: AsyncStream<Void>

    @ObservationIgnored private let reconnectContinuation: AsyncStream<Void>.Continuation
    @ObservationIgnored private var pathProvider: (any PathProvider)?

    /// Single ordered ingress for the two off-actor signals (OS path + request
    /// outcomes). Both feed ``ingest(isOnline:)``, which `yield`s here; one
    /// consumer task drains it on the main actor in FIFO order. This is the
    /// load-bearing detail behind last-write-wins: independently spawned
    /// `Task { @MainActor }` hops have **no** ordering guarantee on the main
    /// actor's serial executor, so two near-simultaneous signals (a failing
    /// request racing a satisfied path, or two concurrent requests with opposite
    /// outcomes) could apply out of submission order and leave ``isOnline``
    /// reflecting the *stale* signal. `yield` enqueues in call order and a single
    /// `for await` dequeues in that order, so the most-recent signal always wins.
    @ObservationIgnored private let signals: AsyncStream<Bool>
    @ObservationIgnored private let signalContinuation: AsyncStream<Bool>.Continuation
    @ObservationIgnored private var consumer: Task<Void, Never>?

    /// - Parameter initiallyOnline: the optimistic starting value before the
    ///   first signal arrives. Defaults to `true` so the banner stays hidden
    ///   until something proves we're offline.
    public init(initiallyOnline: Bool = true) {
        self.isOnline = initiallyOnline
        let (reconnectStream, reconnectContinuation) = AsyncStream<Void>.makeStream(
            bufferingPolicy: .bufferingNewest(1)
        )
        self.reconnects = reconnectStream
        self.reconnectContinuation = reconnectContinuation
        // Unbounded so no submitted signal is silently dropped before the
        // consumer drains it; the values are tiny Bools and the consumer keeps
        // pace, so the buffer stays shallow.
        let (signalStream, signalContinuation) = AsyncStream<Bool>.makeStream()
        self.signals = signalStream
        self.signalContinuation = signalContinuation
        self.consumer = Task { [weak self] in
            for await value in signalStream {
                guard let self else { break }
                self.apply(isOnline: value)
            }
        }
    }

    deinit {
        signalContinuation.finish()
        consumer?.cancel()
        reconnectContinuation.finish()
    }

    /// Begin tracking the OS network path. Retains `pathProvider` and forwards
    /// every `.satisfied`/not transition into the ordered ``signals`` funnel.
    /// Call once at launch. The provider's callback may land on any queue, so it
    /// goes through ``ingest(isOnline:)`` (a `nonisolated` `yield`) rather than a
    /// fresh main-actor `Task`, keeping it ordered against request outcomes.
    public func start(pathProvider: any PathProvider) {
        self.pathProvider = pathProvider
        pathProvider.start { [weak self] satisfied in
            self?.ingest(isOnline: satisfied)
        }
    }

    /// Ordered, thread-safe ingress for the two off-actor signals. `nonisolated`
    /// so the `@Sendable` path callback and the ``APIClient`` outcome hook can
    /// feed it directly from any thread without spawning their own (unordered)
    /// main-actor `Task`. Submissions apply on the main actor in call order via
    /// the single ``signals`` consumer — see that property for why ordering
    /// matters. `true` = reachable/online, `false` = offline.
    public nonisolated func ingest(isOnline: Bool) {
        signalContinuation.yield(isOnline)
    }

    /// Correct the signal from a real request's transport result, applied
    /// **synchronously** on the main actor. `false` (a thrown `URLError`) latches
    /// offline even under a satisfied path; `true` (the server answered, any
    /// status) restores online.
    ///
    /// For callers already on the main actor (and direct tests). The production
    /// outcome hook arrives off-actor and uses ``ingest(isOnline:)`` instead, so
    /// it stays ordered against path updates; do not mix the two for the same
    /// monitor from concurrent contexts.
    public func noteOutcome(success: Bool) {
        apply(isOnline: success)
    }

    /// The single mutation funnel for both signals, so the reconnect edge is
    /// detected once regardless of cause and last-write-wins falls out naturally.
    private func apply(isOnline newValue: Bool) {
        let wasOnline = isOnline
        isOnline = newValue
        if !wasOnline && newValue {
            reconnectContinuation.yield()
        }
    }
}
