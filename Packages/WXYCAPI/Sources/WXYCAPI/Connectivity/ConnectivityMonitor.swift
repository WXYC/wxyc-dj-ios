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
    public let reconnects: AsyncStream<Void>

    @ObservationIgnored private let reconnectContinuation: AsyncStream<Void>.Continuation
    @ObservationIgnored private var pathProvider: (any PathProvider)?

    /// - Parameter initiallyOnline: the optimistic starting value before the
    ///   first signal arrives. Defaults to `true` so the banner stays hidden
    ///   until something proves we're offline.
    public init(initiallyOnline: Bool = true) {
        self.isOnline = initiallyOnline
        let (stream, continuation) = AsyncStream<Void>.makeStream()
        self.reconnects = stream
        self.reconnectContinuation = continuation
    }

    deinit {
        reconnectContinuation.finish()
    }

    /// Begin tracking the OS network path. Retains `pathProvider` and forwards
    /// every `.satisfied`/not transition into ``isOnline``. Call once at launch.
    /// The provider's callback may land on any queue, so it hops to the main
    /// actor before mutating state.
    public func start(pathProvider: any PathProvider) {
        self.pathProvider = pathProvider
        pathProvider.start { [weak self] satisfied in
            Task { @MainActor in
                self?.apply(isOnline: satisfied)
            }
        }
    }

    /// Correct the signal from a real request's transport result. `false` (a
    /// thrown `URLError`) latches offline even under a satisfied path; `true`
    /// (the server answered, any status) restores online.
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
