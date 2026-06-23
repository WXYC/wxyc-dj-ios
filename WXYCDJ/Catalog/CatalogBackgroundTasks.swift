//
//  CatalogBackgroundTasks.swift
//  WXYCDJ
//
//  The BackgroundTasks plumbing for the on-device catalog refresh (issue #19
//  step 5): the two BGTask identifiers, the submit/scheduling calls, and the
//  ~15-line BGProcessingTask bridge that drives the shared CatalogRefreshService.
//  A split design — a cheap BGAppRefreshTask poll re-arms and, on a 200, submits
//  a charging-gated BGProcessingTask reindex — keeps the heavy work off the
//  ~30 s app-refresh budget.
//
//  Created by Jake on 06/23/26.
//  Copyright © 2026 WXYC. All rights reserved.
//

import BackgroundTasks
import Foundation
import OSLog

/// Module-wide logger for the catalog clone/refresh subsystem. Subsystem matches
/// the rest of the app (`org.wxyc.dj`); category `catalog` sits alongside the
/// detail view's `metadata` category.
let catalogLog = Logger(subsystem: "org.wxyc.dj", category: "catalog")

/// Identifiers and scheduling for the catalog's two background legs (issue #19
/// step 5). The poll leg (`BGAppRefreshTask`) is registered by SwiftUI's native
/// `.backgroundTask(.appRefresh:)` scene modifier; the reindex leg
/// (`BGProcessingTask`) is registered here from the `AppDelegate` because
/// SwiftUI has no `.processing` matcher. Both identifiers must appear in the
/// `BGTaskSchedulerPermittedIdentifiers` array in `project.yml`'s `info:` block.
enum CatalogBackgroundTasks {
    /// `BGAppRefreshTask` — the cheap conditional poll. `UIBackgroundModes: fetch`.
    static let pollIdentifier = "org.wxyc.dj.catalog.refresh"
    /// `BGProcessingTask` — the multi-MB download + ~50k-row decode + Spotlight
    /// reindex, run while charging. `UIBackgroundModes: processing`.
    static let reindexIdentifier = "org.wxyc.dj.catalog.reindex"

    /// How far out to hint the next poll. `earliestBeginDate` is only a hint —
    /// iOS schedules based on usage, battery, and Low Power Mode, so this is a
    /// floor, not a guarantee.
    private static let pollInterval: TimeInterval = 4 * 60 * 60

    // MARK: Scheduling

    /// Submit (or replace) the pending app-refresh poll request. Called when the
    /// app leaves the foreground and re-armed by the poll handler itself, so the
    /// poll leg self-perpetuates. Submitting a second request for the same
    /// identifier replaces the pending one, so this is idempotent.
    static func scheduleNextPoll() {
        let request = BGAppRefreshTaskRequest(identifier: pollIdentifier)
        request.earliestBeginDate = Date(timeIntervalSinceNow: pollInterval)
        submit(request)
    }

    /// Submit the charging-gated reindex processing request. Called by the poll
    /// handler when a conditional GET reports the catalog moved, so the heavy
    /// download + reindex runs on external power instead of the ~30 s
    /// app-refresh budget.
    static func scheduleReindex() {
        let request = BGProcessingTaskRequest(identifier: reindexIdentifier)
        request.requiresExternalPower = true
        request.requiresNetworkConnectivity = true
        submit(request)
    }

    /// Submit a request, logging (never throwing) on failure. The simulator and
    /// a force-quit app both reject submission with
    /// `BGTaskSchedulerErrorCodeUnavailable`/`NotPermitted`; that is expected and
    /// non-fatal — background refresh is best-effort, the foreground path is the
    /// floor.
    private static func submit(_ request: BGTaskRequest) {
        do {
            try BGTaskScheduler.shared.submit(request)
        } catch {
            catalogLog.error("Failed to submit BGTask \(request.identifier, privacy: .public): \(error.localizedDescription, privacy: .public)")
        }
    }

    // MARK: Reindex-leg registration

    /// Register the `BGProcessingTask` reindex handler. Must run before the app
    /// finishes launching (called from `AppDelegate.application(_:didFinishLaunchingWithOptions:)`).
    /// The poll leg is registered separately by SwiftUI's `.backgroundTask`.
    static func registerReindexHandler(dependencies: AppDependencies) {
        let registered = BGTaskScheduler.shared.register(
            forTaskWithIdentifier: reindexIdentifier,
            using: nil
        ) { task in
            handleReindexTask(task, dependencies: dependencies)
        }
        if !registered {
            catalogLog.error("Failed to register reindex BGTask \(reindexIdentifier, privacy: .public)")
        }
    }

    /// Drive one reindex `BGProcessingTask` through the shared refresh service.
    /// The launch handler runs on a private background queue and hands us a
    /// non-`Sendable` `BGTask`; `nonisolated(unsafe)` lets the `work` task below
    /// capture it. That is sound because only `work` ever touches `task` (calls
    /// `setTaskCompleted`); the expiration block captures only the `Sendable`
    /// `work`, never `task`. `setTaskCompleted` is therefore called exactly once,
    /// reporting the refresh's *real* outcome (not whether it was cancelled). The
    /// reindex is idempotent: it re-derives "is there still a 200 waiting?" from
    /// its own conditional GET (`refresh()`), so a foreground refresh that already
    /// advanced the watermark makes this a cheap `304`.
    private static func handleReindexTask(_ task: BGTask, dependencies: AppDependencies) {
        nonisolated(unsafe) let task = task
        let work = Task {
            let succeeded = await dependencies.refreshCatalog()
            task.setTaskCompleted(success: succeeded)
        }
        // Best-effort cancellation if iOS reclaims our background time. This is a
        // cooperative signal, not true preemption: refresh()'s pipeline runs in
        // the service's own single-flighted task and won't observe this cancel
        // mid-batch, so the work may run to completion (then report) before the
        // process is suspended. That's safe — the store/index transaction is
        // atomic and the watermark only advances on a successful Spotlight commit,
        // so an interrupted reindex leaves the prior watermark and the next run
        // (with a fresh indexer) retries.
        task.expirationHandler = {
            work.cancel()
        }
    }
}
