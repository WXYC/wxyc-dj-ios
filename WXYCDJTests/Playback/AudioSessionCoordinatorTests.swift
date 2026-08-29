//
//  AudioSessionCoordinatorTests.swift
//  WXYCDJTests
//
//  Drives AudioSessionCoordinator (issue #137) through its three ported
//  behaviours against FakeAudioSession: the category is configured lazily
//  and at most once; a CannotInterruptOthers failure retries up to the
//  bounded budget then gives up; a self-handback (this coordinator's own
//  in-flight deactivation) defers activation without spending that budget
//  and resumes once the handback completes; a deactivation whose generation
//  goes stale before it runs is a no-op, while a fresh one deactivates once.
//
//  Created by Jake Bromberg on 08/29/26.
//  Copyright © 2026 WXYC. All rights reserved.
//

import Testing
@testable import WXYCDJ

@MainActor
struct AudioSessionCoordinatorTests {
    @Test("the category is configured on first activate(), never at init, and at most once")
    func categoryConfiguredLazilyOnFirstActivateNeverAtInit() {
        let session = FakeAudioSession()
        let coordinator = AudioSessionCoordinator(session: session)

        #expect(session.categoryCalls.isEmpty, "the category must not be configured at init")

        #expect(coordinator.activate())
        #expect(session.categoryCalls == [
            FakeAudioSession.CategoryCall(category: .playback, mode: .default, policy: .default, options: [])
        ])

        #expect(coordinator.activate())
        #expect(session.categoryCalls.count == 1, "the category must be configured at most once")
    }

    @Test("a CannotInterruptOthers failure retries up to the bounded budget then gives up")
    func cannotInterruptOthersRetriesUpToTheBudgetThenGivesUp() async {
        let session = FakeAudioSession()
        session.failAllActivations(with: FakeAudioSession.cannotInterruptOthersError())
        let coordinator = AudioSessionCoordinator(session: session, maxRetryAttempts: 4, retryDelay: .milliseconds(5))

        let activated = coordinator.activate()
        #expect(activated == false)

        await waitUntil { coordinator.activationRetryAttempts == 4 }
        await waitUntil { !coordinator.activationPending }

        #expect(coordinator.activationRetryAttempts == 4)
        #expect(!coordinator.isActivated)
        // 1 initial attempt (from activate()) + 4 bounded retries.
        #expect(session.activateCallCount == 5)
    }

    @Test("a self-handback defers activation without spending the retry budget, then resumes when it completes")
    func selfHandbackDefersActivationWithoutSpendingBudgetThenResumes() async {
        let session = FakeAudioSession()
        let coordinator = AudioSessionCoordinator(session: session, maxRetryAttempts: 4, retryDelay: .milliseconds(5))

        #expect(coordinator.activate())
        #expect(session.activateCallCount == 1)

        session.holdDeactivations()
        coordinator.deactivate()

        await waitUntil { session.isBlockingOnHold }

        let activatedWhileBusy = coordinator.activate()
        #expect(activatedWhileBusy == false, "activate() must defer behind the in-flight handback")
        #expect(session.activateCallCount == 1, "a busy handback must not attempt setActive(true, …) at all")

        // Held well past retryDelay, and checked *while still held*: if
        // activate() had wrongly routed this through the bounded retry loop
        // instead of the handback-deferred path, that loop's own
        // Task.sleep(retryDelay) would have elapsed by now and it would have
        // recorded an attempt before ever discovering the session is still
        // busy. Checking only after releaseDeactivations() below wouldn't
        // catch that -- the loop's retry task gets cancelled by the
        // resumed activate() the instant it succeeds, often before its first
        // tick, so a wrongly-scheduled retry can slip past an
        // after-the-fact assertion on luck alone.
        try? await Task.sleep(for: .milliseconds(50))
        #expect(coordinator.activationRetryAttempts == 0, "the self-handback path must never spend the bounded-retry budget")

        session.releaseDeactivations()

        await waitUntil { coordinator.deactivationSettledCount == 1 }
        await waitUntil { session.activateCallCount == 2 }

        #expect(coordinator.isActivated, "the deferred activation was never resumed after the handback completed")
        #expect(session.activateCallCount == 2, "expected exactly one re-activation after the handback")
        #expect(coordinator.activationRetryAttempts == 0, "resuming behind a handback must never touch the bounded-retry counter")
    }

    @Test("a deactivation whose generation goes stale before it runs declines rather than tearing down the reactivated session")
    func staleDeactivationDeclines() async {
        let session = FakeAudioSession()
        let coordinator = AudioSessionCoordinator(session: session)

        #expect(coordinator.activate())
        // Synchronous, back to back, with no `await` in between: deactivate()
        // captures the current generation and only *queues* its Task, which
        // cannot run until this turn yields. The activate() immediately after
        // therefore reactivates -- bumping the generation -- before the
        // queued deactivation ever gets a chance to check it.
        coordinator.deactivate()
        #expect(coordinator.activate())

        await waitUntil { coordinator.deactivationSettledCount == 1 }

        #expect(coordinator.isActivated, "a stale deactivation tore down the reactivated session")
        #expect(session.deactivateCallCount == 0, "the stale deactivation called setActive(false, …) anyway")
        #expect(session.activateCallCount == 2, "expected exactly two activations: the initial one and the reactivation")
    }

    @Test("a deactivation under a fresh generation deactivates exactly once")
    func freshGenerationDeactivatesOnce() async {
        let session = FakeAudioSession()
        let coordinator = AudioSessionCoordinator(session: session)

        #expect(coordinator.activate())
        coordinator.deactivate()

        await waitUntil { coordinator.deactivationSettledCount == 1 }

        #expect(!coordinator.isActivated)
        #expect(session.deactivateCallCount == 1)
        #expect(session.activateCallCount == 1)
    }

    @Test("deactivate() without a prior activate() is a no-op")
    func deactivateWithoutActivateIsANoOp() async {
        let session = FakeAudioSession()
        let coordinator = AudioSessionCoordinator(session: session)

        coordinator.deactivate()

        // Give any (incorrectly) scheduled work a chance to run before
        // asserting its absence.
        await Task.yield()
        #expect(coordinator.deactivationSettledCount == 0)
        #expect(session.deactivateCallCount == 0)
    }
}

/// Polls `condition` on the main actor until it holds, yielding between
/// checks. Matches the idiom in `LoginViewModelTests.swift`.
@MainActor
private func waitUntil(_ condition: () -> Bool) async {
    for _ in 0..<1_000 where !condition() {
        await Task.yield()
    }
}
