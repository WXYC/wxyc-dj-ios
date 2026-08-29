//
//  AudioSessionCoordinatorTests.swift
//  WXYCDJTests
//
//  Drives AudioSessionCoordinator (issue #137) through its three ported
//  behaviours against FakeAudioSession: the category is configured lazily
//  and at most once; a CannotInterruptOthers failure retries up to the
//  bounded budget then gives up while a hard failure spends none of it; a
//  self-handback (this coordinator's own in-flight deactivation) defers
//  activation without spending that budget and resumes once the handback
//  completes; a deactivation whose generation goes stale before it runs is a
//  no-op, while a fresh one deactivates once, passing
//  .notifyOthersOnDeactivation.
//
//  Plus the three guards a deactivate() has to hold over an activation that
//  hasn't happened yet or a handback that hasn't finished: it cancels a
//  pending bounded retry, it cancels an activation deferred behind a
//  handback, and a second deactivate() inside the handback window coalesces
//  into the first rather than stacking a duplicate setActive(false, …) --
//  and is then re-driven rather than dropped in the two cases where that
//  first handback returns having released nothing, stale or refused.
//
//  Created by Jake Bromberg on 08/29/26.
//  Copyright © 2026 WXYC. All rights reserved.
//

import Foundation
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
        // The options, not just the counts: `.notifyOthersOnDeactivation` is
        // what tells every other audio app on the device it may resume, and
        // it is the detail an extraction drops most quietly.
        #expect(session.setActiveCalls == [
            FakeAudioSession.SetActiveCall(active: true, options: []),
            FakeAudioSession.SetActiveCall(active: false, options: .notifyOthersOnDeactivation)
        ])
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

    @Test("a non-'!int' activation failure gives up immediately rather than spending the retry budget")
    func hardActivationFailureDoesNotScheduleARetry() async {
        let session = FakeAudioSession()
        session.failNextActivation(with: NSError(domain: "org.wxyc.dj.test", code: -1))
        let coordinator = AudioSessionCoordinator(session: session, maxRetryAttempts: 4, retryDelay: .milliseconds(5))

        #expect(coordinator.activate() == false)
        #expect(!coordinator.activationPending, "a hard failure must not arm a deferred activation")

        // Well past maxRetryAttempts * retryDelay, and the fake reverts to
        // succeeding after the one scripted failure -- so a wrongly-scheduled
        // retry wouldn't just tick, it would *activate*, which is exactly the
        // outcome the .failed arm exists to withhold.
        try? await Task.sleep(for: .milliseconds(60))

        #expect(session.activateCallCount == 1, "a hard failure must not schedule the bounded retry")
        #expect(coordinator.activationRetryAttempts == 0)
        #expect(!coordinator.isActivated)
    }

    @Test("deactivate() during a pending bounded retry cancels the activation instead of doing nothing")
    func deactivateDuringPendingRetryCancelsTheDeferredActivation() async {
        let session = FakeAudioSession()
        session.failAllActivations(with: FakeAudioSession.cannotInterruptOthersError())
        let coordinator = AudioSessionCoordinator(session: session, maxRetryAttempts: 4, retryDelay: .milliseconds(5))

        #expect(coordinator.activate() == false)
        #expect(coordinator.activationPending, "the CannotInterruptOthers failure should have armed the bounded retry")
        #expect(!coordinator.isActivated, "the deferred state under test is one where isActivated is still false")

        // The other app releases the session, so every later attempt would
        // succeed...
        session.stopFailingActivations()
        // ...but the caller withdrew its request first. deactivate() has
        // nothing to hand back here -- cancelling the pending activation is
        // its entire job on this path, and the isActivated guard must not
        // short-circuit past it.
        coordinator.deactivate()
        #expect(!coordinator.activationPending, "deactivate() left a deferred activation armed")

        try? await Task.sleep(for: .milliseconds(60))

        #expect(session.activateCallCount == 1, "the bounded retry activated a session the caller had asked to release")
        #expect(coordinator.activationRetryAttempts == 0)
        #expect(!coordinator.isActivated)
        #expect(session.deactivateCallCount == 0, "there was no active session to hand back")
    }

    @Test("deactivate() during a handback cancels the activation deferred behind it, leaving the session inactive")
    func deactivateDuringHandbackCancelsTheDeferredResume() async {
        let session = FakeAudioSession()
        let coordinator = AudioSessionCoordinator(session: session)

        #expect(coordinator.activate())

        session.holdDeactivations()
        coordinator.deactivate()
        await waitUntil { session.isBlockingOnHold }

        // An activate() lands mid-handback and parks on its completion.
        #expect(coordinator.activate() == false)
        #expect(coordinator.activationPending)

        // The caller changes its mind again before the handback finishes.
        // Nothing else can cancel this deferral: the handback's continuation
        // re-drives it unconditionally otherwise.
        coordinator.deactivate()

        session.releaseDeactivations()
        await waitUntil { coordinator.deactivationSettledCount == 1 }
        try? await Task.sleep(for: .milliseconds(20))

        #expect(!coordinator.isActivated, "the deferred activation re-activated a session the caller had asked to release")
        #expect(session.activateCallCount == 1, "expected no re-activation after the handback")
        #expect(session.deactivateCallCount == 1)
    }

    @Test("a second deactivate() inside the handback window coalesces instead of stacking a duplicate handback")
    func secondDeactivateDuringHandbackDoesNotStackASecondSetActiveFalse() async {
        let session = FakeAudioSession()
        let coordinator = AudioSessionCoordinator(session: session)

        #expect(coordinator.activate())

        session.holdDeactivations()
        coordinator.deactivate()
        await waitUntil { session.isBlockingOnHold }

        // isActivated is still true here -- it is cleared only once the
        // handback is *confirmed*, which is why it cannot serve as the
        // in-flight guard and why this second call would otherwise queue a
        // second detached task: one that blocks a cooperative-pool thread on
        // sessionLock for the rest of the handback, then passes its own
        // generation check (only an activation bumps the generation) and
        // re-fans the resume notification to every other audio app.
        #expect(coordinator.isActivated)
        coordinator.deactivate()

        session.releaseDeactivations()
        await waitUntil { coordinator.deactivationSettledCount == 1 }
        // A stacked handback would be unblocked by the same release and land
        // shortly after the first settles, so give it room to show up.
        try? await Task.sleep(for: .milliseconds(50))

        #expect(session.deactivateCallCount == 1, "the second deactivate() stacked a duplicate setActive(false, …)")
        #expect(!coordinator.isActivated)
        #expect(session.activateCallCount == 1)
    }

    // The two tests above pin the *coalescing* half of that guard -- that the
    // second call doesn't stack a duplicate handback. These two pin its other
    // half: that the coalesced request is re-driven rather than dropped. The
    // distinction is not academic. Deleting drainRequestedDeactivation()
    // leaves every other test in this file green, because in all of them the
    // in-flight handback ultimately succeeds and the re-driven deactivate()
    // then early-returns on `guard isActivated`. Both cases below are ones
    // where the in-flight handback returns without handing anything back --
    // stale, then failed -- which is exactly when the coalesced request is
    // the only thing left that would ever release the session.

    @Test("a handback that declines as stale re-drives the request that coalesced into it")
    func staleHandbackReDrivesTheCoalescedRequest() async {
        let session = FakeAudioSession()
        let coordinator = AudioSessionCoordinator(session: session)

        #expect(coordinator.activate())

        // All four calls land in one synchronous turn, so the handback queued
        // by the first deactivate() cannot run until they have: it captures
        // generation 1; the activate() reactivates under generation 2 (the
        // session lock is free -- the handback hasn't started); and the
        // second deactivate() finds deactivationInFlight still set, so it is
        // recorded as the coalesced request rather than scheduling its own.
        coordinator.deactivate()
        #expect(coordinator.activate())
        coordinator.deactivate()

        // Two settles, not two calls: the stale handback, then the one the
        // drain re-drives. See deactivationSettledCount's doc comment.
        await waitUntil { coordinator.deactivationSettledCount == 2 }

        // Without the re-drive the first handback declines as stale, nothing
        // picks the request back up, and the session is left ACTIVE after the
        // caller's last instruction was deactivate().
        #expect(!coordinator.isActivated, "the coalesced request was dropped when the handback went stale")
        #expect(session.deactivateCallCount == 1, "expected exactly one real handback, under the new generation")
        #expect(
            session.setActiveCalls.last == FakeAudioSession.SetActiveCall(active: false, options: .notifyOthersOnDeactivation),
            "the re-driven handback dropped .notifyOthersOnDeactivation"
        )
        #expect(session.activateCallCount == 2)
    }

    @Test("a handback that fails with a request coalesced into it retries rather than leaving the session active")
    func failedHandbackReDrivesTheCoalescedRequest() async {
        let session = FakeAudioSession()
        let coordinator = AudioSessionCoordinator(session: session)

        #expect(coordinator.activate())

        session.holdDeactivations()
        session.failNextDeactivation(with: NSError(domain: "test.handback", code: 1))
        coordinator.deactivate()
        await waitUntil { session.isBlockingOnHold }

        // Lands inside the handback window and coalesces into the in-flight
        // call -- which is about to be refused, so it hands nothing back.
        coordinator.deactivate()

        session.releaseDeactivations()
        await waitUntil { coordinator.deactivationSettledCount == 2 }

        // isActivated deliberately stays set on a refused handback so that the
        // next deactivate() retries. The caller already issued its last one,
        // so the drain is what supplies that next call -- without it the retry
        // this design depends on simply never happens.
        #expect(!coordinator.isActivated, "the retry a refused handback relies on never happened")
        #expect(session.deactivateCallCount == 2, "expected the refused handback and exactly one retry")
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
