import AVFoundation
import Foundation
import Testing
import WatchKit
@testable import SonaWatch

// The recorder on fakes: no mic, no notification centre, no real disk numbers.

final class FakeCapture: AudioCapture {
    var currentTime: TimeInterval
    /// What AVAudioRecorder.isRecording would say; a test turns it off to play a recorder that died quietly.
    var isRecording = true
    private(set) var stopped = false

    init(seconds: Double) { currentTime = seconds }

    func stop() {
        stopped = true
        isRecording = false
    }
    func decibels() -> Float { -30 }
}

/// Writes a WAV the way AVAudioRecorder leaves one before it stops (the sizes still 0), `seconds` long, beside the
/// `.aac` it's asked for (the fallback). With `aacFrames`, it writes that many ADTS frames at the `.aac` instead.
final class FakeMic: MicHardware {
    var onEvent: (@MainActor (String, RecorderEvent) -> Void)?
    var allowed = true
    /// The next this many starts fail, as if a call still had the mic.
    var failStarts = 0
    var seconds = 2
    var aacFrames: Int?
    private(set) var startAttempts = 0
    private(set) var sessionActive = false
    private(set) var captures: [FakeCapture] = []

    func requestPermission() async -> Bool { allowed }
    func activateSession() throws { sessionActive = true }
    func deactivateSession() { sessionActive = false }

    func startRecording(to url: URL) throws -> any AudioCapture {
        startAttempts += 1
        if failStarts > 0 {
            failStarts -= 1
            throw CocoaError(.fileWriteUnknown)
        }
        #expect(url.pathExtension == "aac")
        if let aacFrames {
            try synthesizedADTS(frames: aacFrames).write(to: url)
        } else {
            try synthesizedWAV(samples: seconds * 16_000).write(to: url.deletingPathExtension().appendingPathExtension("wav"))
        }
        let capture = FakeCapture(seconds: Double(seconds))
        captures.append(capture)
        return capture
    }

    /// What the real delegate does when AVFoundation reports in.
    func report(_ id: String, _ event: RecorderEvent) { onEvent?(id, event) }
}

final class FakeNotifier: StopNotifier {
    private(set) var permissionRequests = 0
    /// What would be on the wrist now: the last notification not taken back.
    private(set) var shown: (stop: UnexpectedStop, delay: TimeInterval)?
    private(set) var posted: [UnexpectedStop] = []

    func askPermission() { permissionRequests += 1 }

    func notify(_ stop: UnexpectedStop, after delay: TimeInterval) {
        shown = (stop, delay)
        posted.append(stop)
    }

    func clear() { shown = nil }

    /// The reminders pending now, with when each would fire.
    private(set) var pending: [RecordingReminder: TimeInterval] = [:]
    private(set) var scheduled: [RecordingReminder] = []

    func schedule(_ reminder: RecordingReminder, after delay: TimeInterval) {
        pending[reminder] = delay
        scheduled.append(reminder)
    }

    func cancel(_ reminder: RecordingReminder) { pending[reminder] = nil }
}

/// A recorder on fakes, with a folder of its own. Waits are short; nothing checks storage by itself unless a test
/// says so.
struct Rig {
    final class World {
        var freeBytes: Int64? = 8_000_000_000
        var haptics: [WKHapticType] = []
        var changes = 0
        var clock = Date(timeIntervalSince1970: 1_000_000)
    }

    let store: RecordingStore
    let mic: FakeMic
    let notifier: FakeNotifier
    let center: NotificationCenter
    let world: World
    let recorder: WatchRecorder

    init(store: RecordingStore? = nil) throws {
        let store = try store ?? RecordingStore(dir: temporaryFolder())
        let mic = FakeMic()
        let notifier = FakeNotifier()
        let center = NotificationCenter()
        let world = World()
        let recorder = WatchRecorder(
            store: store,
            platform: RecorderPlatform(
                mic: mic, notifier: notifier, freeBytes: { _ in world.freeBytes },
                haptic: { world.haptics.append($0) }, center: center))
        recorder.now = { world.clock }
        recorder.onChange = { world.changes += 1 }
        // The health check's clock moves with the test's, unless a test sets the wall clock apart from it.
        recorder.clock = { world.clock.timeIntervalSinceReferenceDate }
        recorder.checkStorageEvery = .seconds(3600)
        recorder.resumeRetryDelays = [.milliseconds(1), .milliseconds(1)]
        recorder.saveRetryDelays = [.milliseconds(5), .milliseconds(5), .milliseconds(5)]
        (self.store, self.mic, self.notifier, self.center, self.world, self.recorder) =
            (store, mic, notifier, center, world, recorder)
    }
}

/// Polls until the condition holds: the recorder's background work (a timer, a notification) is done.
@MainActor
func waitUntil(_ condition: () -> Bool) async -> Bool {
    let deadline = ContinuousClock.now + .seconds(5)
    while !condition(), ContinuousClock.now < deadline { try? await Task.sleep(for: .milliseconds(5)) }
    return condition()
}

@MainActor
struct WatchRecorderTests {
    // MARK: Plain start and stop

    @Test func startsAndStopsAndKeepsTheLength() async throws {
        let rig = try Rig()
        await rig.recorder.start()
        let id = try #require(rig.recorder.currentID)
        #expect(rig.recorder.isRecording)
        #expect(rig.store.load(id)?.duration == 0)  // saved first: a crash now leaves something to repair
        #expect(rig.notifier.permissionRequests == 0)  // asked once it stops, not over the Stop button
        #expect(rig.world.haptics == [.start])

        rig.recorder.stop()

        #expect(rig.notifier.permissionRequests == 1)
        #expect(!rig.recorder.isRecording)
        #expect(rig.recorder.currentID == nil)
        #expect(rig.store.load(id)?.duration == 2)
        #expect(rig.mic.captures[0].stopped)
        #expect(!rig.mic.sessionActive)
        #expect(rig.notifier.posted.isEmpty)  // he stopped it: nothing to tell him
        #expect(rig.world.haptics == [.start, .stop])
    }

    @Test func noMicPermissionMeansNoRecording() async throws {
        let rig = try Rig()
        rig.mic.allowed = false
        await rig.recorder.start()
        #expect(!rig.recorder.isRecording)
        #expect(rig.store.all().isEmpty)
        #expect(rig.recorder.message?.contains("can't use the mic") == true)
        #expect(rig.notifier.permissionRequests == 0)
    }

    @Test func aMicThatWontStartLeavesNothingBehind() async throws {
        let rig = try Rig()
        rig.mic.failStarts = 1
        await rig.recorder.start()
        #expect(!rig.recorder.isRecording)
        #expect(rig.store.all().isEmpty)
        #expect(!rig.mic.sessionActive)
        #expect(rig.recorder.message == "The mic didn't start. Try again.")
    }

    // MARK: A call or Siri (#9)

    @Test func aCallSavesTheRecordingAndItsEndStartsANewOne() async throws {
        let rig = try Rig()
        await rig.recorder.start()
        let first = try #require(rig.recorder.currentID)

        await rig.recorder.interrupted(.began)

        // Saved as it is, and no longer recording.
        #expect(!rig.recorder.isRecording)
        #expect(rig.recorder.currentID == nil)
        #expect(rig.store.load(first)?.duration == 2)
        #expect(rig.mic.captures[0].stopped)
        #expect(rig.mic.sessionActive)  // left on, so the system can hand the mic back
        // If nothing has the mic back soon, a notification says so.
        #expect(rig.notifier.shown?.stop == .interrupted)
        #expect(rig.notifier.shown?.delay == InterruptionPolicy.notifyAfter)

        await rig.recorder.interrupted(.ended(shouldResume: true))

        // A new recording, with a new id; the first stays whole.
        let second = try #require(rig.recorder.currentID)
        #expect(second != first)
        #expect(rig.recorder.isRecording)
        #expect(rig.recorder.message?.contains("Carried on after a call") == true)
        #expect(rig.world.haptics.last == .start)
        #expect(rig.notifier.shown == nil)  // no need for the safety net now
        #expect(Set(rig.store.all().map(\.id)) == [first, second])
        #expect(rig.store.load(first)?.duration == 2)
        #expect(rig.store.load(second)?.duration == 0)
    }

    @Test func theFirstPartIsQueuedForTheIPhoneAtOnce() async throws {
        let rig = try Rig()
        let session = FakeSession()
        let queue = TransferQueue(
            store: rig.store, session: session, defaults: UserDefaults(suiteName: "sona-tests-\(UUID().uuidString)")!)
        // What AppModel does when a recording starts or stops.
        rig.recorder.onChange = {
            queue.recordingID = rig.recorder.currentID
            queue.run()
        }
        await rig.recorder.start()
        let first = try #require(rig.recorder.currentID)
        #expect(session.sent.isEmpty)

        await rig.recorder.interrupted(.began)
        #expect(session.sent == [first])

        await rig.recorder.interrupted(.ended(shouldResume: true))
        let second = try #require(rig.recorder.currentID)
        #expect(queue.recordingID == second)
        queue.run()
        #expect(session.sent == [first])  // the new one isn't sent until it stops
        #expect(queue.waiting == 1)
    }

    @Test func theEndStartsANewOneEvenWithoutShouldResume() async throws {
        let rig = try Rig()
        await rig.recorder.start()
        let first = try #require(rig.recorder.currentID)
        await rig.recorder.interrupted(.began)
        await rig.recorder.interrupted(.ended(shouldResume: false))
        #expect(rig.recorder.isRecording)
        #expect(rig.recorder.currentID != first)
    }

    @Test func anEndWithNothingToResumeStartsNothing() async throws {
        let rig = try Rig()
        await rig.recorder.interrupted(.ended(shouldResume: true))
        #expect(!rig.recorder.isRecording)
        #expect(rig.mic.startAttempts == 0)
        await rig.recorder.interrupted(.began)  // a call while not recording
        await rig.recorder.interrupted(.ended(shouldResume: true))
        #expect(rig.mic.startAttempts == 0)
        #expect(rig.notifier.posted.isEmpty)
    }

    @Test func startingByHandDuringTheCallIsNotDoubledByTheEnd() async throws {
        let rig = try Rig()
        await rig.recorder.start()
        await rig.recorder.interrupted(.began)
        await rig.recorder.start()
        let byHand = try #require(rig.recorder.currentID)

        await rig.recorder.interrupted(.ended(shouldResume: true))

        #expect(rig.recorder.currentID == byHand)
        #expect(rig.mic.captures.count == 2)
    }

    @Test func aMicThatComesBackLateIsTriedAgain() async throws {
        let rig = try Rig()
        await rig.recorder.start()
        await rig.recorder.interrupted(.began)
        rig.mic.failStarts = 1  // still busy for the first try

        await rig.recorder.interrupted(.ended(shouldResume: true))

        #expect(rig.recorder.isRecording)
        #expect(rig.mic.startAttempts == 3)  // the first recording, the failed try, the one that worked
        #expect(rig.notifier.shown == nil)
        #expect(rig.recorder.message?.contains("Carried on after a call") == true)
    }

    @Test func aRestartThatFailsPostsANotification() async throws {
        let rig = try Rig()
        await rig.recorder.start()
        let first = try #require(rig.recorder.currentID)
        await rig.recorder.interrupted(.began)
        rig.mic.failStarts = 10  // the mic never comes back

        await rig.recorder.interrupted(.ended(shouldResume: true))

        #expect(!rig.recorder.isRecording)
        #expect(rig.mic.startAttempts == 4)  // the first recording, then now and two more tries
        #expect(rig.notifier.shown?.stop == .couldNotResume)
        #expect(rig.notifier.shown?.delay == 0)  // at once, replacing the safety net
        #expect(rig.recorder.message?.contains("Couldn't carry on") == true)
        #expect(rig.world.haptics.last == .failure)
        #expect(!rig.mic.sessionActive)
        // What was recorded before the call is safe, and nothing half-made is left.
        #expect(rig.store.all().map(\.id) == [first])
        #expect(rig.store.load(first)?.duration == 2)
    }

    @Test func noRoomAtTheRestartIsFinalAndSaysWhy() async throws {
        let rig = try Rig()
        await rig.recorder.start()
        await rig.recorder.interrupted(.began)
        rig.world.freeBytes = 20_000_000

        await rig.recorder.interrupted(.ended(shouldResume: true))

        #expect(!rig.recorder.isRecording)
        #expect(rig.mic.startAttempts == 1)  // no point trying again
        #expect(rig.notifier.shown?.stop == .couldNotResume)
        #expect(rig.recorder.message == "Watch storage is nearly full. Free some up to record.")
    }

    @Test func anEndHoursLaterIsNotResumed() async throws {
        let rig = try Rig()
        await rig.recorder.start()
        await rig.recorder.interrupted(.began)
        rig.world.clock += InterruptionPolicy.resumeWindow + 60

        await rig.recorder.interrupted(.ended(shouldResume: true))

        #expect(!rig.recorder.isRecording)
        #expect(rig.mic.startAttempts == 1)
        #expect(rig.notifier.shown?.stop == .interrupted)  // the safety net already told him
    }

    @Test func theSystemsNotificationsReachTheRecorder() async throws {
        let rig = try Rig()
        await rig.recorder.start()
        let first = try #require(rig.recorder.currentID)

        rig.center.post(
            name: AVAudioSession.interruptionNotification, object: nil,
            userInfo: [AVAudioSessionInterruptionTypeKey: AVAudioSession.InterruptionType.began.rawValue])
        #expect(await waitUntil { !rig.recorder.isRecording })
        #expect(rig.store.load(first)?.duration == 2)

        rig.center.post(
            name: AVAudioSession.interruptionNotification, object: nil,
            userInfo: [
                AVAudioSessionInterruptionTypeKey: AVAudioSession.InterruptionType.ended.rawValue,
                AVAudioSessionInterruptionOptionKey: AVAudioSession.InterruptionOptions.shouldResume.rawValue,
            ])
        #expect(await waitUntil { rig.recorder.isRecording })
        #expect(rig.recorder.currentID != first)
    }

    // MARK: A late callback from the recorder before (#16)

    @Test func aLateCallbackFromTheLastRecordingDoesNotStopTheNextOne() async throws {
        let rig = try Rig()
        await rig.recorder.start()
        let first = try #require(rig.recorder.currentID)
        rig.recorder.stop()
        await rig.recorder.start()
        let second = try #require(rig.recorder.currentID)
        #expect(first != second)

        // The first recorder's delegate, after its stop(), now that the second is going.
        rig.mic.report(first, .finished)
        rig.mic.report(first, .failed)

        #expect(rig.recorder.isRecording)
        #expect(rig.recorder.currentID == second)
        #expect(rig.recorder.message == nil)
        #expect(rig.notifier.posted.isEmpty)
        #expect(!rig.mic.captures[1].stopped)
    }

    @Test func aCallbackWithNothingRecordingChangesNothing() async throws {
        let rig = try Rig()
        await rig.recorder.start()
        let id = try #require(rig.recorder.currentID)
        rig.recorder.stop()
        let changes = rig.world.changes
        rig.mic.report(id, .finished)  // our own stop(), landing after the fact
        #expect(rig.world.changes == changes)
        #expect(rig.recorder.message == nil)
        #expect(rig.notifier.posted.isEmpty)
    }

    @Test func theCurrentRecordingsOwnReportStillStopsItAndTellsHim() async throws {
        let rig = try Rig()
        await rig.recorder.start()
        let id = try #require(rig.recorder.currentID)

        rig.mic.report(id, .finished)

        #expect(!rig.recorder.isRecording)
        #expect(rig.store.load(id)?.duration == 2)
        #expect(rig.recorder.message == "Recording stopped. Saved.")
        #expect(rig.notifier.shown?.stop == .recorderStopped)
    }

    @Test func anEncodeErrorStopsItToo() async throws {
        let rig = try Rig()
        await rig.recorder.start()
        let id = try #require(rig.recorder.currentID)
        rig.mic.report(id, .failed)
        #expect(!rig.recorder.isRecording)
        #expect(rig.recorder.message == "Recording hit an error. Saved what was recorded.")
        #expect(rig.notifier.shown?.stop == .recorderStopped)
    }

    @Test func theRealDelegateSaysWhichRecordingSpoke() async throws {
        // A real AVAudioRecorder that never records: only its url is read.
        let store = RecordingStore(dir: try temporaryFolder())
        let id = UUID().uuidString
        #expect(RecordingStore.id(ofAudio: store.aacURL(id)) == id)
        #expect(RecordingStore.id(ofAudio: store.wavURL(id)) == id)

        let mic = SystemMic()
        var heard: [String] = []
        var events: [RecorderEvent] = []
        mic.onEvent = { id, event in
            heard.append(id)
            events.append(event)
        }
        let recorder = try AVAudioRecorder(url: store.aacURL(id), settings: SystemMic.aacSettings)
        mic.audioRecorderDidFinishRecording(recorder, successfully: true)
        mic.audioRecorderEncodeErrorDidOccur(recorder, error: nil)

        #expect(await waitUntil { heard.count == 2 })
        #expect(heard == [id, id])
        #expect(events == [.finished, .failed])
    }

    // MARK: Storage (#10)

    @Test func refusesToStartWithLittleStorageAndSaysSo() async throws {
        let rig = try Rig()
        rig.world.freeBytes = 99_000_000
        await rig.recorder.start()
        #expect(!rig.recorder.isRecording)
        #expect(rig.recorder.message == "Watch storage is nearly full. Free some up to record.")
        #expect(rig.store.all().isEmpty)
        #expect(rig.mic.startAttempts == 0)
        #expect(rig.world.haptics == [.failure])
    }

    @Test func startsWithEnoughStorageOrWhenItCantTell() async throws {
        let rig = try Rig()
        rig.world.freeBytes = 100_000_000
        await rig.recorder.start()
        #expect(rig.recorder.isRecording)
        rig.recorder.stop()
        rig.world.freeBytes = nil
        await rig.recorder.start()
        #expect(rig.recorder.isRecording)
    }

    @Test func stopsAndSavesWhenStorageRunsLow() async throws {
        let rig = try Rig()
        await rig.recorder.start()
        let id = try #require(rig.recorder.currentID)

        rig.world.freeBytes = 60_000_000  // under what it takes to start, but a running recording goes on
        rig.recorder.checkStorage()
        #expect(rig.recorder.isRecording)

        rig.world.freeBytes = 49_000_000
        rig.recorder.checkStorage()

        #expect(!rig.recorder.isRecording)
        #expect(rig.store.load(id)?.duration == 2)
        #expect(rig.recorder.message == "Watch storage is nearly full. Stopped and saved.")
        #expect(rig.notifier.shown?.stop == .lowStorage)
        #expect(!rig.mic.sessionActive)
    }

    @Test func checksStorageOnItsOwnWhileRecording() async throws {
        let rig = try Rig()
        rig.recorder.checkStorageEvery = .milliseconds(10)
        await rig.recorder.start()
        let id = try #require(rig.recorder.currentID)
        try await Task.sleep(for: .milliseconds(40))
        #expect(rig.recorder.isRecording)  // plenty of room

        rig.world.freeBytes = 10_000_000

        #expect(await waitUntil { !rig.recorder.isRecording })
        #expect(rig.store.load(id)?.duration == 2)
        #expect(rig.notifier.shown?.stop == .lowStorage)
    }

    @Test func stopsCheckingOnceStopped() async throws {
        let rig = try Rig()
        rig.recorder.checkStorageEvery = .milliseconds(10)
        await rig.recorder.start()
        rig.recorder.stop()
        rig.world.freeBytes = 10_000_000
        try await Task.sleep(for: .milliseconds(50))
        #expect(rig.notifier.posted.isEmpty)
    }

    // MARK: A final save that fails (#10)

    final class Switch { var failing = false }

    /// A store whose JSON writes fail while the switch is on, as when the disk is full.
    func flakyStore(_ flip: Switch) throws -> RecordingStore {
        var store = RecordingStore(dir: try temporaryFolder())
        store.write = { data, url in
            if flip.failing { throw CocoaError(.fileWriteOutOfSpace) }
            try data.write(to: url, options: .atomic)
        }
        return store
    }

    @Test func aFailedFinalSaveIsTriedAgain() async throws {
        let flip = Switch()
        let rig = try Rig(store: flakyStore(flip))
        await rig.recorder.start()
        let id = try #require(rig.recorder.currentID)

        flip.failing = true
        rig.recorder.stop()
        #expect(rig.store.load(id)?.duration == 0)  // the save failed: the JSON still says it never stopped
        let changes = rig.world.changes

        flip.failing = false
        #expect(await waitUntil { rig.store.load(id)?.duration == 2 })
        #expect(await waitUntil { rig.world.changes > changes })  // and the queue is told
    }

    @Test func aRetryNeverWritesOverWhatTheQueueAlreadyRepairedAndSent() async throws {
        let flip = Switch()
        let rig = try Rig(store: flakyStore(flip))
        let session = FakeSession()
        let queue = TransferQueue(
            store: rig.store, session: session, defaults: UserDefaults(suiteName: "sona-tests-\(UUID().uuidString)")!)
        await rig.recorder.start()
        let id = try #require(rig.recorder.currentID)

        flip.failing = true
        rig.recorder.stop()
        flip.failing = false
        queue.run()  // finds the recording stuck at 0, repairs it and sends it
        #expect(session.sent == [id])
        let sentAt = try #require(rig.store.load(id)?.sentAt)

        try await Task.sleep(for: .milliseconds(100))  // longer than all the retries
        #expect(rig.store.load(id)?.sentAt == sentAt)
        #expect(rig.store.load(id)?.duration == 2)
    }

    @Test func aRecordingNobodyCouldSaveIsStillFoundByTheQueue() async throws {
        let flip = Switch()
        let rig = try Rig(store: flakyStore(flip))
        let session = FakeSession()
        let queue = TransferQueue(
            store: rig.store, session: session, defaults: UserDefaults(suiteName: "sona-tests-\(UUID().uuidString)")!)
        rig.recorder.saveRetryDelays = []  // no retries at all
        await rig.recorder.start()
        let id = try #require(rig.recorder.currentID)

        flip.failing = true
        rig.recorder.stop()
        flip.failing = false
        #expect(rig.store.load(id)?.duration == 0)
        #expect(queue.waiting == 0)  // invisible so far

        queue.run()

        #expect(queue.waiting == 1)
        #expect(session.sent == [id])
    }
}
