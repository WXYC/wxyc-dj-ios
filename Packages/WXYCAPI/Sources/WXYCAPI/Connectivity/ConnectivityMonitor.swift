//
//  ConnectivityMonitor.swift
//  WXYCAPI
//
//  App-wide observable online/offline signal, corrected by real request
//  outcomes — not just the OS path. The OS reachability comes through the
//  PathProvider seam; a transport failure or success from APIClient overrides
//  it (last-write-wins). Owned by the composition root like AuthService and read
//  by the offline banner (#56) and the rest of the offline epic (#58–#61).
//  Issue #81 adds a half-open probe (circuit-breaker sense): once latched
//  offline for at least `probeCooldown`, `consumeProbe()` lets exactly one
//  caller attempt the server anyway, so a surface with no other network
//  activity (library search) can self-recover instead of staying latched
//  forever.
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
///
/// A third, narrower mechanism supplements those two: once latched offline for
/// at least `probeCooldown`, ``isHalfOpen``/``consumeProbe()`` (issue #81) let a
/// caller with no other pending network activity — ``LibrarySearch`` is the
/// first — attempt one real request anyway. That request's own outcome still
/// flows through the ordinary ``ingest(isOnline:)``/``noteOutcome(success:)``
/// hook, so success or failure is handled exactly like any other request; the
/// half-open machinery only decides *whether* one gets attempted.
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

    /// How long a caller must wait after the monitor latches offline (or a
    /// half-open probe subsequently fails) before ``consumeProbe()`` allows
    /// another attempt. Issue #81's chosen middle ground: long enough that a
    /// down backend isn't hammered on every keystroke, short enough that a DJ
    /// who's actually back online self-recovers without leaving the search tab.
    public static let defaultProbeCooldown: TimeInterval = 30

    @ObservationIgnored private let probeCooldown: TimeInterval
    @ObservationIgnored private let now: @Sendable () -> Date
    /// When the current offline window began, per the most recent offline
    /// signal — the initial online→offline latch, or a later half-open probe
    /// reporting failure (which restarts the cooldown from that failure, not
    /// the original latch). `nil` while online.
    @ObservationIgnored private var offlineSince: Date?
    /// The `offlineSince` value a probe was already claimed for. Compared by
    /// value (not a plain "claimed" `Bool`) so a probe failure — which moves
    /// `offlineSince` forward — automatically re-opens eligibility for the new
    /// window without any extra bookkeeping.
    @ObservationIgnored private var probeClaimedOfflineSince: Date?

    /// - Parameters:
    ///   - initiallyOnline: the optimistic starting value before the first
    ///     signal arrives. Defaults to `true` so the banner stays hidden until
    ///     something proves we're offline. `false` starts the half-open
    ///     cooldown immediately, anchored at construction time.
    ///   - probeCooldown: see ``defaultProbeCooldown``.
    ///   - now: the time source `isHalfOpen`/``consumeProbe()`` measure the
    ///     cooldown against. Defaults to the wall clock; tests inject a
    ///     stubbed clock so the cooldown is exercised deterministically with
    ///     no wall-clock sleeps.
    public init(
        initiallyOnline: Bool = true,
        probeCooldown: TimeInterval = defaultProbeCooldown,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.isOnline = initiallyOnline
        self.probeCooldown = probeCooldown
        self.now = now
        self.offlineSince = initiallyOnline ? nil : now()
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

    /// `true` when the monitor is latched offline, ``defaultProbeCooldown``
    /// (or the injected `probeCooldown`) has elapsed since the current offline
    /// window began, and no probe has yet been claimed for that window — i.e.
    /// the next call to ``consumeProbe()`` would succeed. Read-only: checking
    /// it has no side effects, so callers (and tests) can observe eligibility
    /// without spending the allowance.
    public var isHalfOpen: Bool {
        guard !isOnline, let offlineSince else { return false }
        guard probeClaimedOfflineSince != offlineSince else { return false }
        return now().timeIntervalSince(offlineSince) >= probeCooldown
    }

    /// Atomically claim the current offline window's one allowed half-open
    /// probe (issue #81, circuit-breaker "half-open" sense). A caller that
    /// gets `true` back is the single one that should attempt a real request
    /// despite ``isOnline`` being `false`; every other caller — concurrent, or
    /// merely later within the same cooldown window — gets `false`. That's
    /// what keeps "N attempts inside one cooldown window produce at most one
    /// server hit" true regardless of how many call sites read this monitor
    /// (``LibrarySearch`` today; `AlbumDetailView`, `BinViewModel`,
    /// `CatalogRefreshService` are documented future readers who'd want the
    /// same allowance rather than each inventing their own cooldown).
    ///
    /// The claim is spent the instant it's issued — it does not wait to see
    /// whether the caller's subsequent request succeeds or fails. A caller
    /// reports that outcome through the ordinary hook
    /// (``ingest(isOnline:)``/``noteOutcome(success:)``) exactly like any other
    /// request: success clears the offline window in ``apply(isOnline:)`` (the
    /// latch lifts and ``reconnects`` fires "for free"); failure keeps the
    /// window open but moves ``offlineSince`` forward to the failure's
    /// timestamp, restarting the cooldown so the next allowed probe is a full
    /// `probeCooldown` away again — "costing one timeout" as the issue puts it,
    /// not an open door.
    ///
    /// Synchronous and `@MainActor`-isolated with no `await` between the
    /// eligibility check and the claim, so two calls issued back to back on the
    /// main actor's serial executor can never both observe `true`.
    public func consumeProbe() -> Bool {
        guard isHalfOpen else { return false }
        probeClaimedOfflineSince = offlineSince
        return true
    }

    /// The single mutation funnel for both signals, so the reconnect edge is
    /// detected once regardless of cause and last-write-wins falls out naturally.
    private func apply(isOnline newValue: Bool) {
        let wasOnline = isOnline
        isOnline = newValue
        if newValue {
            // Online again, whatever the cause: the half-open bookkeeping only
            // means something while latched offline, so drop it entirely. A
            // later latch starts a fresh offline window with its own cooldown.
            offlineSince = nil
            probeClaimedOfflineSince = nil
            if !wasOnline {
                reconnectContinuation.yield()
            }
        } else {
            // Still (or newly) offline. Move the anchor on *every* offline
            // signal, not just the online->offline transition: a claimed
            // half-open probe that fails reports `false` here too, and that
            // failure should restart the cooldown rather than let a stale
            // offlineSince make the very next caller re-probe immediately.
            offlineSince = now()
        }
    }
}
