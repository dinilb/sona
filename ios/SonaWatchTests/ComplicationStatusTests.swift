import Foundation
import Testing
@testable import SonaWatch

/// When the watch asks its complications to reload. Reloads have a budget, so it doesn't repeat itself; but a reload
/// iOS dropped is saved all the same, so what's saved can't be what it compares with.
@MainActor
struct ComplicationStatusTests {
    /// Stands in for the App Group and WidgetKit: what's saved, and how many reloads were asked for.
    final class FakeStore {
        var saved: SharedStatus
        var saves = 0
        var reloads = 0

        init(saved: SharedStatus = SharedStatus()) { self.saved = saved }

        var store: ComplicationStatus.Store {
            ComplicationStatus.Store(
                load: { self.saved },
                save: {
                    self.saved = $0
                    self.saves += 1
                },
                reload: { self.reloads += 1 })
        }
    }

    let start = Date(timeIntervalSince1970: 1_793_000_000)

    @Test func theFirstPublishReloadsEvenWhenWhatIsSavedAlreadySaysTheSame() {
        // A run before this one saved this and asked for a reload; if iOS dropped it, the complication is stale and
        // only another reload fixes it.
        let fake = FakeStore(saved: SharedStatus(recordingSince: nil, waiting: 0))
        let complications = ComplicationStatus(store: fake.store)
        #expect(complications.publish(recordingSince: nil, waiting: 0))
        #expect(fake.reloads == 1)
        #expect(fake.saves == 1)
        #expect(fake.saved.recordingSince == nil)
        #expect(fake.saved.waiting == 0)

        // A new process (a new one of these) asks once again, whatever is saved.
        let later = ComplicationStatus(store: fake.store)
        #expect(later.publish(recordingSince: nil, waiting: 0))
        #expect(fake.reloads == 2)
    }

    @Test func reloadsWhenWhatItDrawsChangesAndNotWhenItDoesNot() {
        let fake = FakeStore()
        let complications = ComplicationStatus(store: fake.store)
        #expect(complications.publish(recordingSince: nil, waiting: 0))
        // The queue reports after every transfer; nothing changed, so nothing is saved or reloaded.
        #expect(!complications.publish(recordingSince: nil, waiting: 0))
        #expect(!complications.publish(recordingSince: nil, waiting: 0))
        #expect(fake.reloads == 1)
        #expect(fake.saves == 1)

        // A recording starts: the complication says so.
        #expect(complications.publish(recordingSince: start, waiting: 0))
        #expect(!complications.publish(recordingSince: start, waiting: 0))
        #expect(fake.saved.recordingSince == start)
        #expect(fake.reloads == 2)

        // It stops and waits to go to the iPhone.
        #expect(complications.publish(recordingSince: nil, waiting: 1))
        #expect(fake.saved.recordingSince == nil)
        #expect(fake.saved.waiting == 1)
        // The iPhone has it.
        #expect(complications.publish(recordingSince: nil, waiting: 0))
        #expect(fake.saved.waiting == 0)
        #expect(fake.reloads == 4)
        #expect(fake.saves == 4)
    }

    @Test func aNewRecordingIsADifferentThingToDraw() {
        let fake = FakeStore()
        let complications = ComplicationStatus(store: fake.store)
        #expect(complications.publish(recordingSince: start, waiting: 0))
        // One recording ends and the next starts between two publishes: the time the complication counts from moved.
        #expect(complications.publish(recordingSince: start.addingTimeInterval(90), waiting: 0))
        #expect(fake.saved.recordingSince == start.addingTimeInterval(90))
        #expect(fake.reloads == 2)
    }

    @Test func afterTheFirstPublishWhatIsSavedDoesNotDecide() {
        let fake = FakeStore()
        let complications = ComplicationStatus(store: fake.store)
        #expect(complications.publish(recordingSince: start, waiting: 1))
        // The saved copy is changed from outside; what this process last asked the complications to draw is not.
        fake.saved = SharedStatus()
        #expect(!complications.publish(recordingSince: start, waiting: 1))
        #expect(fake.reloads == 1)
        #expect(fake.saves == 1)
    }
}

/// The watch's own recorder drives its complications, wired as the app wires it (`AppModel.connect`): a start reloads
/// them with that recording's start time (the iPhone's never reach the watch), the minute check keeps it counting
/// without a reload, and a stop reloads them with nothing recording and the recording waiting for the iPhone.
@MainActor
struct ComplicationWiringTests {
    @Test func aRecordingOnThisWatchReloadsTheComplicationAtItsStartAndItsStop() async throws {
        let rig = try Rig()
        let queue = TransferQueue(
            store: rig.store, session: FakeSession(),
            defaults: UserDefaults(suiteName: "sona-tests-\(UUID().uuidString)")!)
        let fake = ComplicationStatusTests.FakeStore()
        let complications = ComplicationStatus(store: fake.store)
        let world = rig.world
        complications.now = { world.clock }
        AppModel.connect(recorder: rig.recorder, queue: queue, complications: complications)

        await rig.recorder.start()
        let started = try #require(rig.recorder.startedAt)
        #expect(fake.saved.recordingSince == started)
        #expect(fake.saved.liveRecordingSince(now: started.addingTimeInterval(60)) == started)
        #expect(fake.saved.waiting == 0)
        #expect(fake.reloads == 1)

        let capture = try #require(rig.mic.captures.first)
        world.clock += 60
        capture.currentTime = 60
        rig.recorder.checkAlive()
        #expect(rig.recorder.isRecording)
        #expect(fake.saved.aliveAt == world.clock)
        #expect(fake.reloads == 1)

        rig.recorder.stop()
        #expect(fake.saved.recordingSince == nil)
        #expect(fake.saved.liveRecordingSince(now: world.clock) == nil)
        #expect(fake.saved.waiting == 1)
        #expect(fake.reloads == 2)
    }
}
