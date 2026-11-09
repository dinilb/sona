import AVFoundation
import Foundation
import Testing
@testable import SonaWatch

// v1 watch fixes: a delivered recording isn't sent again every hour, the iPhone is woken and its inventory acks,
// a recorder that quietly stops is caught, a call off screen doesn't restart the mic, a heartbeat for the
// complication, and an I/O error never deletes a recording.

@MainActor
struct V1WatchTransferTests {
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

    @Test func aDeliveredRecordingIsNeverSentAgainOnTheHourlyTimer() throws {
        let recording = try record()
        queue.run()
        queue.transferFinished(id: recording.id, failed: false)
        #expect(store.load(recording.id)?.deliveredAt == clock)

        later(WatchTransferPolicy.resendAfter * 3)
        queue.run()

        #expect(session.sent == [recording.id])
        #expect(queue.waiting == 1)  // still waiting on the iPhone for Sona to run
    }

    @Test func anInventoryNewerThanTheDeliveryThatLeavesItOutSendsItOnce() throws {
        let recording = try record()
        queue.run()
        queue.transferFinished(id: recording.id, failed: false)
        later(WatchTransferPolicy.resendAfter + 1)

        // Sona on the iPhone was reinstalled: it has nothing.
        queue.inventoryArrived(PhoneInventory(ids: [], at: clock.addingTimeInterval(WatchTransferPolicy.resendAfter)))

        #expect(session.sent == [recording.id, recording.id])
        #expect(store.load(recording.id)?.deliveredAt == nil)  // a new transfer, not delivered yet
        queue.run()
        #expect(session.sent.count == 2)
    }

    @Test func anInventoryJustAfterTheDeliveryDoesNotSendItAgain() throws {
        let recording = try record()
        queue.run()
        queue.transferFinished(id: recording.id, failed: false)
        later(WatchTransferPolicy.resendAfter + 1)

        // Within the margin: the file may still be on its way into Sona.
        queue.inventoryArrived(PhoneInventory(ids: [], at: clock.addingTimeInterval(60)))

        #expect(session.sent == [recording.id])
    }

    @Test func anInventoryOlderThanTheDeliveryDoesNotSendItAgain() throws {
        let recording = try record()
        queue.run()
        later(10)
        queue.transferFinished(id: recording.id, failed: false)
        later(WatchTransferPolicy.resendAfter * 2)

        queue.inventoryArrived(PhoneInventory(ids: [], at: clock))

        #expect(session.sent == [recording.id])
    }

    @Test func anInventoryThatListsARecordingAcknowledgesIt() throws {
        let listed = try record()
        let other = try record()
        queue.run()

        queue.inventoryArrived(PhoneInventory(ids: [listed.id, UUID().uuidString], at: clock))

        #expect(store.load(listed.id) == nil)
        #expect(!FileManager.default.fileExists(atPath: store.wavURL(listed.id).path))
        #expect(queue.sent.map(\.id) == [listed.id])
        #expect(store.load(other.id) != nil)
        #expect(queue.waiting == 1)
    }

    @Test func anOlderInventoryThanTheOneKnownIsIgnored() throws {
        let recording = try record()
        queue.run()
        queue.inventoryArrived(PhoneInventory(ids: [], at: clock.addingTimeInterval(100)))
        queue.inventoryArrived(PhoneInventory(ids: [recording.id], at: clock))
        #expect(store.load(recording.id) != nil)
        #expect(queue.phoneInventory?.at == clock.addingTimeInterval(100))
    }

    @Test func theIPhoneIsWokenWhileAnythingWaitsAndNotOtherwise() throws {
        queue.run()
        #expect(session.wakes == 0)  // nothing to take

        let recording = try record()
        queue.run()
        #expect(session.wakes == 1)
        queue.run()  // one of a burst (activation, the iPhone's inventory): the iPhone is already up
        #expect(session.wakes == 1)
        later(WakePolicy.quietFor)
        queue.cameForward()  // already handed over, still waiting: nudged again (the watch app is in front again)
        #expect(session.wakes == 2)

        queue.transferFinished(id: recording.id, failed: false)  // on the iPhone now: always nudged
        #expect(session.wakes == 3)

        queue.acknowledged(id: recording.id)
        queue.run()
        #expect(session.wakes == 3)
    }

    @Test func nothingIsWokenWithoutASession() throws {
        session.canSend = false
        _ = try record()
        queue.run()
        #expect(session.wakes == 0)
    }

    @Test func aFailedTransferClearsTheDelivery() throws {
        let recording = try record()
        queue.run()
        queue.transferFinished(id: recording.id, failed: false)
        queue.transferFinished(id: recording.id, failed: true)
        #expect(store.load(recording.id)?.deliveredAt == nil)
        #expect(store.load(recording.id)?.sentAt == nil)
        queue.run()
        #expect(session.sent == [recording.id, recording.id])
    }

    // MARK: A repair that throws (R2-11)

    /// Audio that exists but can't be opened for writing: a folder by that name. `WAVFile.repair` and
    /// `ADTSFile.scan` both throw on it.
    func unreadable(_ format: String) throws -> (WatchRecording, URL) {
        let recording = WatchRecording(startedAt: Date(), duration: 0)
        try store.save(recording)
        let audio = format == "wav" ? store.wavURL(recording.id) : store.aacURL(recording.id)
        try FileManager.default.createDirectory(at: audio, withIntermediateDirectories: true)
        return (recording, audio)
    }

    @Test(arguments: ["wav", "aac"])
    func aRepairThatThrowsKeepsTheRecordingForTheNextRun(format: String) throws {
        let (recording, audio) = try unreadable(format)

        queue.run()
        #expect(store.load(recording.id) != nil)
        #expect(FileManager.default.fileExists(atPath: audio.path))
        #expect(session.sent.isEmpty)

        store.recover()
        #expect(store.load(recording.id) != nil)
        #expect(FileManager.default.fileExists(atPath: audio.path))
    }
}

struct V1WatchContractTests {
    @Test func aRecordingSavedByAnOlderBuildStillReads() throws {
        let old = #"{"id":"6F9619FF-8B86-D011-B42D-00C04FC964FF","startedAt":0,"duration":3}"#
        let recording = try JSONDecoder().decode(WatchRecording.self, from: Data(old.utf8))
        #expect(recording.duration == 3)
        #expect(recording.deliveredAt == nil)
    }

    @Test func theDeliveryIsNeverSentToTheIPhone() {
        let recording = WatchRecording(startedAt: Date(), duration: 1, sentAt: Date(), deliveredAt: Date())
        #expect(recording.metadata["deliveredAt"] == nil)
        #expect(WatchRecording(metadata: recording.metadata)?.deliveredAt == nil)
    }

    @Test func anInventoryRoundTrips() {
        let at = Date(timeIntervalSince1970: 1_800_000_000)
        let inventory = PhoneInventory(ids: ["a", "b"], at: at)
        #expect(PhoneInventory(context: inventory.context) == inventory)
        #expect(PhoneInventory(context: ["kind": "other", "ids": ["a"], "at": 1.0]) == nil)
        #expect(PhoneInventory(context: [:]) == nil)
    }

    @Test func aWakeIsNotAnAcknowledgement() {
        #expect(Ack.id(in: Wake.message) == nil)
        #expect(Wake.message["kind"] as? String == Wake.kind)
    }
}

@MainActor
struct V1WatchRecorderTests {
    final class Counter { var count = 0 }

    @Test func remindersAreScheduledWhileRecordingAndTakenBackAtTheStop() async throws {
        let rig = try Rig()
        await rig.recorder.start()
        #expect(rig.notifier.pending[.mayHaveStopped] == HealthPolicy.watchdogAfter)
        #expect(rig.notifier.pending[.stillRecording] == HealthPolicy.stillRecordingAfter)

        rig.recorder.stop()

        #expect(rig.notifier.pending.isEmpty)
    }

    @Test func aHealthyCheckMovesTheWatchdogOnAndBeatsTheHeart() async throws {
        let rig = try Rig()
        let beats = Counter()
        rig.recorder.onHealthy = { beats.count += 1 }
        await rig.recorder.start()
        let capture = try #require(rig.mic.captures.first)
        let scheduled = rig.notifier.scheduled.count

        rig.world.clock += 60
        capture.currentTime = 60
        rig.recorder.checkAlive()

        #expect(rig.recorder.isRecording)
        #expect(beats.count == 1)
        #expect(rig.notifier.scheduled.count == scheduled + 1)
        #expect(rig.notifier.pending[.mayHaveStopped] == HealthPolicy.watchdogAfter)
    }

    @Test func aQuickLookIsTooSoonToJudge() async throws {
        let rig = try Rig()
        await rig.recorder.start()
        let capture = try #require(rig.mic.captures.first)
        capture.currentTime = 0
        rig.world.clock += HealthPolicy.judgeAfter - 1
        rig.recorder.checkAlive()
        #expect(rig.recorder.isRecording)
    }

    @Test func aRecorderThatStoppedWritingIsStoppedAndSaved() async throws {
        let rig = try Rig()
        await rig.recorder.start()
        let id = try #require(rig.recorder.currentID)
        let capture = try #require(rig.mic.captures.first)

        // A minute went by and the recorder wrote 2 seconds of it.
        rig.world.clock += 60
        capture.currentTime = 2
        rig.recorder.checkAlive()

        #expect(!rig.recorder.isRecording)
        #expect(rig.store.load(id)?.duration == 2)
        #expect(rig.notifier.shown?.stop == .recorderStopped)
        #expect(rig.recorder.message?.hasPrefix("Recording stopped on its own after") == true)
        #expect(rig.notifier.pending.isEmpty)
    }

    @Test func aRecorderThatSaysItStoppedIsCaughtWhenHeLooks() async throws {
        let rig = try Rig()
        await rig.recorder.start()
        let capture = try #require(rig.mic.captures.first)
        capture.isRecording = false

        rig.recorder.setVisible(false)
        rig.recorder.setVisible(true)

        #expect(!rig.recorder.isRecording)
        #expect(rig.notifier.shown?.stop == .recorderStopped)
    }

    @Test func aMediaServicesResetSavesWithoutTouchingTheOrphan() async throws {
        let rig = try Rig()
        await rig.recorder.start()
        let id = try #require(rig.recorder.currentID)

        rig.center.post(name: AVAudioSession.mediaServicesWereResetNotification, object: nil)

        #expect(await waitUntil { !rig.recorder.isRecording })
        #expect(rig.mic.captures[0].stopped == false)  // never touched again
        #expect(rig.store.load(id)?.duration == 2)  // the sizes rebuilt from the file
        #expect(rig.notifier.shown?.stop == .recorderStopped)
        #expect(!rig.mic.sessionActive)
    }

    @Test func aCallThatEndsOffScreenIsLeftToHim() async throws {
        let rig = try Rig()
        await rig.recorder.start()
        let first = try #require(rig.recorder.currentID)
        rig.recorder.setVisible(false)  // wrist down

        await rig.recorder.interrupted(.began)
        await rig.recorder.interrupted(.ended(shouldResume: true))

        #expect(!rig.recorder.isRecording)
        #expect(rig.mic.startAttempts == 1)  // no restart from the background
        #expect(!rig.mic.sessionActive)
        #expect(rig.notifier.shown?.stop == .interrupted)
        #expect(rig.notifier.shown?.delay == 0)  // told now, not 30 s on
        #expect(rig.store.all().map(\.id) == [first])
        #expect(rig.notifier.permissionRequests == 0)  // never asked with the wrist down
    }

    @Test func aCallThatEndsAfterTwoMinutesOnScreenIsLeftToHimToo() async throws {
        let rig = try Rig()
        await rig.recorder.start()
        await rig.recorder.interrupted(.began)
        rig.world.clock += InterruptionPolicy.resumeWindow + 1

        await rig.recorder.interrupted(.ended(shouldResume: true))

        #expect(!rig.recorder.isRecording)
        #expect(rig.mic.startAttempts == 1)
        #expect(rig.notifier.shown?.delay == InterruptionPolicy.notifyAfter)  // the one from when the mic went
    }

    @Test func thePolicySaysWhetherToTell() {
        let start = Date(timeIntervalSince1970: 1_000)
        var quick = InterruptionPolicy()
        _ = quick.handle(.began, isRecording: true, now: start)
        #expect(quick.handle(.ended(shouldResume: true), isRecording: false, now: start + 5, onScreen: false)
            == .leaveItToHim(tell: true))
        var slow = InterruptionPolicy()
        _ = slow.handle(.began, isRecording: true, now: start)
        #expect(slow.handle(.ended(shouldResume: true), isRecording: false, now: start + 60, onScreen: false)
            == .leaveItToHim(tell: false))
    }

    @Test func theStallRule() {
        #expect(!HealthPolicy.stalled(wall: 60, audio: 59))
        #expect(!HealthPolicy.stalled(wall: 60, audio: 30))
        #expect(HealthPolicy.stalled(wall: 60, audio: 29))
        #expect(HealthPolicy.stalled(wall: 60, audio: -5))  // the recorder's clock went back to 0: it stopped
        #expect(!HealthPolicy.stalled(wall: 10, audio: 0))  // too soon to say
    }
}

@MainActor
struct V1WatchComplicationTests {
    let start = Date(timeIntervalSince1970: 1_793_000_000)

    @Test func aRecordingStartsItsOwnHeartbeat() {
        // The last recording's heartbeat is still saved: the new one must not read it and look stopped.
        let fake = ComplicationStatusTests.FakeStore(
            saved: SharedStatus(recordingSince: start, aliveAt: start.addingTimeInterval(-3600)))
        let complications = ComplicationStatus(store: fake.store)
        let now = start.addingTimeInterval(7200)
        complications.now = { now }

        complications.publish(recordingSince: now, waiting: 0)

        #expect(fake.saved.aliveAt == now)
        #expect(fake.saved.liveRecordingSince(now: now) == now)
    }

    @Test func theHeartbeatSavesWithoutAReload() {
        let fake = ComplicationStatusTests.FakeStore()
        let complications = ComplicationStatus(store: fake.store)
        var now = start
        complications.now = { now }
        complications.publish(recordingSince: start, waiting: 0)
        let reloads = fake.reloads

        now = start.addingTimeInterval(60)
        complications.heartbeat()

        #expect(fake.saved.aliveAt == now)
        #expect(fake.reloads == reloads)
    }

    @Test func noHeartbeatWhenNothingRecords() {
        let fake = ComplicationStatusTests.FakeStore()
        let complications = ComplicationStatus(store: fake.store)
        complications.publish(recordingSince: nil, waiting: 0)
        let saves = fake.saves
        complications.heartbeat()
        #expect(fake.saves == saves)
        #expect(fake.saved.aliveAt == nil)
    }

    @Test func aRecordingWhoseAppDiedStopsCounting() {
        let status = SharedStatus(recordingSince: start, aliveAt: start.addingTimeInterval(600))
        #expect(status.liveRecordingSince(now: start.addingTimeInterval(600 + SharedStatus.aliveWithin)) == start)
        #expect(status.liveRecordingSince(now: start.addingTimeInterval(601 + SharedStatus.aliveWithin)) == nil)
        // Before its first heartbeat, the start counts as one.
        let fresh = SharedStatus(recordingSince: start)
        #expect(fresh.liveRecordingSince(now: start.addingTimeInterval(60)) == start)
        #expect(fresh.liveRecordingSince(now: start.addingTimeInterval(3600)) == nil)
        #expect(SharedStatus().liveRecordingSince(now: start) == nil)
    }
}
