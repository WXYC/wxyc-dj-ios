//
//  PathProvider.swift
//  WXYCAPI
//
//  A Sendable seam over NWPathMonitor so ConnectivityMonitor's OS-reachability
//  signal is driven by the real network path in production and by a deterministic
//  stub in tests. `import Network` compiles on the package's macOS slice, so the
//  monitor stays host-testable under `swift test`.
//
//  Created by Jake on 6/26/26.
//  Copyright © 2026 WXYC. All rights reserved.
//

import Network

/// Abstracts the OS network-path signal. The real conformer wraps an
/// `NWPathMonitor`; tests substitute a stub that pushes transitions on demand.
public protocol PathProvider: Sendable {
    /// Begin monitoring. `onUpdate(isSatisfied)` is invoked once with the initial
    /// path status and again on every subsequent change. `isSatisfied` is `true`
    /// when the path can carry traffic (`NWPath.Status.satisfied`).
    ///
    /// The callback may arrive on any thread/queue, so it is `@Sendable`; the
    /// consumer (``ConnectivityMonitor``) is responsible for hopping to its actor.
    func start(onUpdate: @escaping @Sendable (Bool) -> Void)
}

/// Production ``PathProvider`` backed by `NWPathMonitor` on a dedicated serial
/// queue, mapping `path.status == .satisfied` to a `Bool`.
public final class RealPathProvider: PathProvider {
    private let monitor: NWPathMonitor
    private let queue: DispatchQueue

    public init() {
        self.monitor = NWPathMonitor()
        self.queue = DispatchQueue(label: "org.wxyc.dj.connectivity.path")
    }

    public func start(onUpdate: @escaping @Sendable (Bool) -> Void) {
        monitor.pathUpdateHandler = { path in
            onUpdate(path.status == .satisfied)
        }
        monitor.start(queue: queue)
    }
}
