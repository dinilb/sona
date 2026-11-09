import Foundation
import Testing
@testable import SonaWatch

// The watch wakes Sona on the iPhone at the moments a wake gets through: a stop (he's looking at the watch), a
// delivery, and the app coming to the front or the iPhone becoming reachable with something still waiting. A wake
// that fails is tried once more, and bursts of runs send one.

struct WakePolicyTests {
    let now = Date(timeIntervalSince1970: 1_000_000)

    func wakes(
        _ reason: WakePolicy.Reason, canSend: Bool = true, reachable: Bool = true, waiting: Bool = true,
        lastWakeAgo: TimeInterval? = nil
    ) -> Bool {
        WakePolicy.shouldWake(
            reason, canSend: canSend, reachable: reachable, waiting: waiting,
            lastWake: lastWakeAgo.map { now.addingTimeInterval(-$0) }, now: now)
    }

    @Test func onlyWhenItGetsThroughAndSomethingWaits() {
        for reason in [WakePolicy.Reason.stopped, .delivered, .cameForward, .run, .retry] {
            #expect(wakes(reason))
            #expect(!wakes(reason, canSend: false))
            #expect(!wakes(reason, reachable: false))  // off screen or out of range: a message wouldn't launch it
            #expect(!wakes(reason, waiting: false))
        }
    }

    @Test func aStopADeliveryAndARetryAlwaysGo() {
        for reason in [WakePolicy.Reason.stopped, .delivered, .retry] {
            #expect(wakes(reason, lastWakeAgo: 0))
            #expect(wakes(reason, lastWakeAgo: 1))
        }
    }

    @Test func aBurstSendsOne() {
        for reason in [WakePolicy.Reason.cameForward, .run] {
            #expect(!wakes(reason, lastWakeAgo: 0))
            #expect(!wakes(reason, lastWakeAgo: WakePolicy.quietFor - 0.1))
            #expect(wakes(reason, lastWakeAgo: WakePolicy.quietFor))
            #expect(wakes(reason, lastWakeAgo: 600))
        }
    }

    @Test func aClockSetBackDoesNotHoldWakesOff() {
        #expect(wakes(.run, lastWakeAgo: -3600))
        #expect(wakes(.cameForward, lastWakeAgo: -1))
    }
}

@MainActor
struct TransferQueueWakeTests {
    let store: RecordingStore
    let session = FakeSession()
    let queue: TransferQueue
    let clock = Date(timeIntervalSince1970: 1_000_000)

    init() throws {
        store = RecordingStore(dir: try temporaryFolder())
        queue = TransferQueue(
            store: store, session: session, defaults: UserDefaults(suiteName: "sona-tests-\(UUID().uuidString)")!)
        let start = clock
        queue.now = { start }
        // A failed wake's retry runs at once, not 2 s later.
        queue.scheduleRetry = { retry in retry() }
    }

    func record(seconds: Double = 2) throws -> WatchRecording {
        let recording = WatchRecording(startedAt: Date(), duration: seconds)
        try store.save(recording)
        try synthesizedWAV(samples: Int(seconds * 16_000)).write(to: store.wavURL(recording.id))
        return recording
    }

    func later(_ seconds: TimeInterval) {
        let then = clock.addingTimeInterval(seconds)
        queue.now = { then }
    }

    @Test func aStopWakesTheIPhoneEvenRightAfterAnotherWake() throws {
        _ = try record()
        queue.run()
        #expect(session.wakes == 1)

        // A new recording starts (nothing to wake for that isn't already woken) and stops at once.
        let next = try record(seconds: 0)
        queue.recordingChanged(to: next.id)
        #expect(session.wakes == 1)
        var stopped = next
        stopped.duration = 2
        try store.save(stopped)
        try synthesizedWAV(samples: 32_000).write(to: store.wavURL(next.id))
        queue.recordingChanged(to: nil)

        #expect(session.wakes == 2)
        #expect(session.sent.contains(next.id))
    }

    @Test func aStopWithTheIPhoneOutOfReachWakesItOnceItIsReachable() throws {
        session.reachable = false
        let recording = try record(seconds: 0)
        queue.recordingChanged(to: recording.id)
        var stopped = recording
        stopped.duration = 2
        try store.save(stopped)
        queue.recordingChanged(to: nil)
        #expect(session.wakes == 0)

        // The app came to the front (a stop from the complication opens it) and the iPhone became reachable a moment
        // later.
        queue.cameForward()
        #expect(session.wakes == 0)
        session.reachable = true
        queue.becameReachable()
        #expect(session.wakes == 1)
    }

    @Test func comingForwardWithNothingWaitingWakesNothing() {
        queue.cameForward()
        queue.becameReachable()
        #expect(session.wakes == 0)
    }

    @Test func aFailedWakeIsTriedOnceMoreAndNoMore() throws {
        _ = try record()
        queue.run()
        #expect(session.wakes == 1)

        session.failWakes()
        #expect(session.wakes == 2)  // the retry

        session.failWakes()
        #expect(session.wakes == 2)  // the retry failed too: the next stop or wrist raise tries again
    }

    @Test func aRetryWithTheIPhoneGoneSendsNothing() throws {
        _ = try record()
        queue.run()
        session.reachable = false  // the wrist went down
        session.failWakes()
        #expect(session.wakes == 1)
    }

    @Test func aRetryForSomethingTheIPhoneTookMeanwhileSendsNothing() throws {
        let recording = try record()
        queue.run()
        queue.acknowledged(id: recording.id)
        session.failWakes()
        #expect(session.wakes == 1)
    }

    @Test func aDeliveryWakesEvenInsideTheQuietSpell() throws {
        let recording = try record()
        queue.run()
        queue.transferFinished(id: recording.id, failed: false)
        #expect(session.wakes == 2)
    }

    @Test func aFailedTransferWakesNothing() throws {
        let recording = try record()
        queue.run()
        later(WakePolicy.quietFor)
        queue.transferFinished(id: recording.id, failed: true)
        #expect(session.wakes == 1)
    }
}

/// Wired as the app wires it (`AppModel.connect`): a stop on the watch wakes the iPhone at once.
@MainActor
struct WakeWiringTests {
    @Test func aStopOnThisWatchWakesTheIPhone() async throws {
        let rig = try Rig()
        let session = FakeSession()
        let queue = TransferQueue(
            store: rig.store, session: session, defaults: UserDefaults(suiteName: "sona-tests-\(UUID().uuidString)")!)
        let world = rig.world
        queue.now = { world.clock }
        AppModel.connect(
            recorder: rig.recorder, queue: queue,
            complications: ComplicationStatus(store: ComplicationStatusTests.FakeStore().store))

        await rig.recorder.start()
        #expect(session.wakes == 0)  // nothing waits while it records

        rig.recorder.stop()
        #expect(session.wakes == 1)
    }
}
