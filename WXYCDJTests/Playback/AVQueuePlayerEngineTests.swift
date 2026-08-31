//
//  AVQueuePlayerEngineTests.swift
//  WXYCDJTests
//
//  AVQueuePlayerEngine (issue #145) is largely the documented-but-untested
//  wiring carve-out ADR 0008 Amendment 3 names -- there is no test harness in
//  this repo for driving a real AVPlayerItem through a *network* failure.
//  Two things are testable anyway, and both are covered here: the pure
//  errorStatusCode -> PlaybackEngineFailure mapping, and the per-item failure
//  observation, which needs no network at all -- an AVPlayerItem over a
//  nonexistent local file reaches `.failed` in well under a second, and the
//  mid-playback failure signal is a NotificationCenter post on the injected
//  centre.
//
//  Created by Jake Bromberg on 08/31/26.
//  Copyright © 2026 WXYC. All rights reserved.
//

import AVFoundation
import Foundation
import os
import Testing
@testable import WXYCDJ

@Suite("AVQueuePlayerEngine.classifyFailure")
struct AVQueuePlayerEngineClassifyFailureTests {
    /// Catches: `case .some(403)` matching any other status, or being
    /// dropped so 403 falls into the `.some` catch-all.
    @Test("403 maps to mediaForbidden -- the only case PlaybackController's refetch acts on")
    func status403MapsToMediaForbidden() {
        #expect(AVQueuePlayerEngine.classifyFailure(errorStatusCode: 403) == .mediaForbidden)
    }

    /// Catches: any non-403 status being folded into `.mediaForbidden`
    /// (which would make PlaybackController spend its one-shot refetch
    /// budget on failures a fresh manifest can never fix) or into
    /// `.decodeFailed` (which would hide a real server refusal behind "the
    /// decoder rejected the bytes").
    @Test("a non-403 HTTP status maps to mediaFailed", arguments: [404, 410, 429, 500, 503])
    func otherStatusesMapToMediaFailed(status: Int) {
        #expect(AVQueuePlayerEngine.classifyFailure(errorStatusCode: status) == .mediaFailed)
    }

    /// Catches: `nil` (no HTTP-level error-log event at all) being folded
    /// into `.mediaFailed` or `.mediaForbidden` instead of `.decodeFailed`.
    @Test("no HTTP status maps to decodeFailed")
    func nilStatusMapsToDecodeFailed() {
        #expect(AVQueuePlayerEngine.classifyFailure(errorStatusCode: nil) == .decodeFailed)
    }
}

// MARK: - Per-item failure observation

/// Lock-guarded event sink, so the consuming `Task` can record off the main
/// actor while the test polls from it.
private final class EventRecorder: @unchecked Sendable {
    private let state = OSAllocatedUnfairLock(initialState: [PlaybackEngineEvent]())
    var events: [PlaybackEngineEvent] { state.withLock { $0 } }
    var failures: [PlaybackEngineFailure] {
        events.compactMap { if case .failed(let failure) = $0 { return failure } else { return nil } }
    }
    func record(_ event: PlaybackEngineEvent) { state.withLock { $0.append(event) } }
}

/// An `AVPlayerItem` already at `.failed`, driven there by a nonexistent local
/// file — no network, and measured at well under a second.
///
/// This is what the engine really meets when `AVQueuePlayer` pre-buffers the
/// *next* item while the current one plays: by the time that item becomes
/// `currentItem` and observers are attached to it, its terminal status is
/// already set.
@MainActor
private func makeAlreadyFailedItem() async throws -> AVPlayerItem {
    let url = URL(fileURLWithPath: "/private/tmp/wxyc-dj-no-such-directory/la-paradoja.mp3")
    let item = AVPlayerItem(asset: AVURLAsset(url: url))
    // Retained for the duration of the wait: an AVPlayer is what drives the
    // item's asset load, and therefore its transition to `.failed`.
    let driver = AVPlayer(playerItem: item)
    driver.play()
    await waitUntil { item.status == .failed }
    try #require(item.status == .failed, "the fixture item must actually be failed for this test to mean anything")
    driver.pause()
    return item
}

@MainActor
@Suite("AVQueuePlayerEngine per-item failure observation")
struct AVQueuePlayerEngineFailureObservationTests {
    @Test("an item that is already failed when observers attach still reports")
    func preBufferedFailureIsReportedAtAttach() async throws {
        let item = try await makeAlreadyFailedItem()
        let engine = AVQueuePlayerEngine(notificationCenter: NotificationCenter())
        let recorder = EventRecorder()
        let consumer = Task { for await event in engine.events { recorder.record(event) } }
        defer { consumer.cancel() }

        engine.attachItemObservers(to: item)
        await waitUntil { !recorder.failures.isEmpty }

        // Catches: reverting the status observation to `options: [.new]` with
        // no attach-time status check. KVO with `.new` alone never fires for a
        // value that was already terminal when the observer was registered, so
        // an item AVQueuePlayer pre-buffered and failed *before* it became
        // current would yield nothing at all: playback stalls silently
        // (AVQueuePlayer only auto-advances on didPlayToEndTime),
        // `isPlaybackRequested` stays true, the mini-player still reads
        // "pause", and the one-shot 403 refetch -- the entire recovery
        // mechanism -- never runs.
        #expect(recorder.failures == [.decodeFailed])
    }

    @Test("a mid-playback failure is reported through failedToPlayToEndTime")
    func failedToPlayToEndTimeIsReported() async throws {
        let center = NotificationCenter()
        let engine = AVQueuePlayerEngine(notificationCenter: center)
        let recorder = EventRecorder()
        let consumer = Task { for await event in engine.events { recorder.record(event) } }
        defer { consumer.cancel() }
        // A healthy item: this failure mode has nothing to do with the item's
        // `status`, which stays `.readyToPlay` when a stream dies mid-track.
        let item = AVPlayerItem(asset: AVURLAsset(url: URL(string: "https://cdn.example.org/1.mp3?sig=A")!))
        engine.attachItemObservers(to: item)

        center.post(name: AVPlayerItem.failedToPlayToEndTimeNotification, object: item)
        await waitUntil { !recorder.failures.isEmpty }

        // Catches: deleting the `failedToPlayToEndTimeNotification` observer.
        // It is the documented signal for a failure *after* an item started
        // playing -- an expiring presigned URL mid-track is exactly that -- and
        // the status KVO cannot see it, because the item never leaves
        // `.readyToPlay`.
        #expect(recorder.failures == [.decodeFailed])
    }

    @Test("one item never reports two failures")
    func failureIsReportedAtMostOncePerItem() async throws {
        let center = NotificationCenter()
        let item = try await makeAlreadyFailedItem()
        let engine = AVQueuePlayerEngine(notificationCenter: center)
        let recorder = EventRecorder()
        let consumer = Task { for await event in engine.events { recorder.record(event) } }
        defer { consumer.cancel() }

        engine.attachItemObservers(to: item)
        await waitUntil { !recorder.failures.isEmpty }
        center.post(name: AVPlayerItem.failedToPlayToEndTimeNotification, object: item)
        await settle()

        // Catches: dropping `reportFailure(for:)`'s
        // `didReportFailureForCurrentItem` guard. With three signals now
        // converging on one item (the attach-time check, the status KVO, and
        // the end-time notification), an ungated report spends
        // PlaybackController's one-shot refetch budget on the first `.failed`
        // and then surfaces the second as a hard `.engine(...)` failure --
        // tearing the queue down for a signature problem the refetch had
        // already fixed.
        #expect(recorder.failures.count == 1)
    }

    @Test("re-attaching to a new item re-arms the failure report")
    func attachingToANewItemReArmsTheReport() async throws {
        let center = NotificationCenter()
        let engine = AVQueuePlayerEngine(notificationCenter: center)
        let recorder = EventRecorder()
        let consumer = Task { for await event in engine.events { recorder.record(event) } }
        defer { consumer.cancel() }
        let first = AVPlayerItem(asset: AVURLAsset(url: URL(string: "https://cdn.example.org/1.mp3?sig=A")!))
        let second = AVPlayerItem(asset: AVURLAsset(url: URL(string: "https://cdn.example.org/2.mp3?sig=B")!))

        engine.attachItemObservers(to: first)
        center.post(name: AVPlayerItem.failedToPlayToEndTimeNotification, object: first)
        await waitUntil { recorder.failures.count == 1 }

        engine.attachItemObservers(to: second)
        center.post(name: AVPlayerItem.failedToPlayToEndTimeNotification, object: second)
        await waitUntil { recorder.failures.count == 2 }

        // Catches: hoisting `didReportFailureForCurrentItem = false` out of
        // `attachItemObservers(to:)` -- the dedup guard above would then latch
        // for the engine's whole lifetime, so the *second* dead URL in a queue
        // would report nothing and the queue would stall in silence.
        #expect(recorder.failures.count == 2)
    }
}

/// Polls `condition` on the main actor until it holds or `timeout` elapses.
/// Yields *and* sleeps, because the waits here depend on real elapsed time
/// (an asset load reaching `.failed`, a notification hop) rather than on
/// main-actor turns.
@MainActor
private func waitUntil(timeout: Duration = .seconds(5), _ condition: () -> Bool) async {
    let deadline = ContinuousClock.now.advanced(by: timeout)
    while !condition(), ContinuousClock.now < deadline {
        await Task.yield()
        try? await Task.sleep(for: .milliseconds(1))
    }
}

/// Lets every in-flight turn drain, for the assertion that a *second* failure
/// did not arrive. Paired in its test with a positive observation on the same
/// pipeline, so the absence is a measurement rather than a vacuous pass.
@MainActor
private func settle() async {
    for _ in 0..<50 { await Task.yield() }
    try? await Task.sleep(for: .milliseconds(30))
    for _ in 0..<50 { await Task.yield() }
}
