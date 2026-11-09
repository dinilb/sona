import Foundation
import Testing
@testable import SonaWatch

/// Stands in for WCSession: records what was sent and lets a test say what's still outstanding.
final class FakeSession: TransferSession {
    var canSend = true
    /// The iPhone is in range and the app in front (only then does a wake go).
    var reachable = true
    var outstandingIDs: Set<String> = []
    private(set) var sent: [String] = []
    private(set) var cancelled: [String] = []
    private(set) var wakes = 0
    /// The failure callbacks of the wakes sent so far, for `failWakes`.
    private var pendingFailures: [@MainActor @Sendable () -> Void] = []

    var isReachable: Bool { canSend && reachable }

    func sendFile(_ url: URL, metadata: [String: Any]) {
        #expect(FileManager.default.fileExists(atPath: url.path))
        sent.append(metadata["id"] as? String ?? "?")
    }

    func cancelTransfers(of id: String) { cancelled.append(id) }

    func wakePhone(failed: @escaping @MainActor @Sendable () -> Void) {
        guard isReachable else { return }
        wakes += 1
        pendingFailures.append(failed)
    }

    /// The wakes sent so far didn't reach the iPhone.
    @MainActor func failWakes() {
        let failures = pendingFailures
        pendingFailures = []
        for failed in failures { failed() }
    }
}

@MainActor
struct TransferQueueTests {
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

    /// A finished recording on the watch.
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

    @Test func sendsEachRecordingOnce() throws {
        let recording = try record()
        queue.run()
        queue.run()
        #expect(session.sent == [recording.id])
        #expect(store.load(recording.id)?.sentAt == clock)
        #expect(queue.waiting == 1)  // until the iPhone says it has it
    }

    @Test func anAcknowledgementDeletesTheRecording() throws {
        let recording = try record()
        queue.run()
        queue.acknowledged(id: recording.id)
        #expect(store.load(recording.id) == nil)
        #expect(!FileManager.default.fileExists(atPath: store.wavURL(recording.id).path))
        #expect(queue.waiting == 0)
        #expect(queue.sent.map(\.id) == [recording.id])
        #expect(session.cancelled == [recording.id])
    }

    @Test func aFailedTransferIsSentAgain() throws {
        let recording = try record()
        queue.run()
        queue.transferFinished(id: recording.id, failed: true)
        #expect(store.load(recording.id)?.sentAt == nil)
        queue.run()
        #expect(session.sent == [recording.id, recording.id])
    }

    @Test func aDeliveredTransferWaitsForItsAcknowledgement() throws {
        let recording = try record()
        queue.run()
        queue.transferFinished(id: recording.id, failed: false)
        queue.run()
        #expect(session.sent == [recording.id])
        #expect(store.load(recording.id) != nil)
    }

    @Test func oneNeverAcknowledgedIsSentAgainAfterResendAfter() throws {
        let recording = try record()
        queue.run()
        later(WatchTransferPolicy.resendAfter - 1)
        queue.run()
        #expect(session.sent == [recording.id])
        later(WatchTransferPolicy.resendAfter + 1)
        queue.run()
        #expect(session.sent == [recording.id, recording.id])
    }

    /// Just after the app starts, a recording sent before waits for the acknowledgements the iPhone queued meanwhile;
    /// one never sent goes at once.
    @Test func aResendWaitsForQueuedAcknowledgementsAtLaunch() throws {
        let old = try record()
        var sent = try #require(store.load(old.id))
        sent.sentAt = clock.addingTimeInterval(-2 * WatchTransferPolicy.resendAfter)  // sent in an earlier launch
        try store.save(sent)
        let fresh = try record()

        queue.run()
        #expect(session.sent == [fresh.id])  // the old one waits
        queue.acknowledged(id: old.id)  // its acknowledgement arrives
        later(queue.ackGrace + 1)
        queue.run()
        #expect(session.sent == [fresh.id])  // nothing to resend: it's gone

        // Without an acknowledgement, it goes once the grace is over.
        let other = try record()
        var stale = try #require(store.load(other.id))
        stale.sentAt = clock.addingTimeInterval(-2 * WatchTransferPolicy.resendAfter)
        try store.save(stale)
        queue.run()
        #expect(session.sent == [fresh.id, other.id])
    }

    @Test func aClockSetBackDoesNotStopResending() throws {
        let recording = try record()
        queue.run()
        later(-WatchTransferPolicy.resendAfter * 2)
        queue.run()
        #expect(session.sent == [recording.id, recording.id])
    }

    @Test func oneStillOutstandingIsNotSentAgain() throws {
        let recording = try record()
        queue.run()
        session.outstandingIDs = [recording.id]
        later(WatchTransferPolicy.resendAfter * 3)
        queue.run()
        #expect(session.sent == [recording.id])
    }

    @Test func theRecordingInProgressIsNotSent() throws {
        let finished = try record()
        let inProgress = WatchRecording(startedAt: Date(), duration: 0)
        try store.save(inProgress)
        queue.recordingID = inProgress.id
        queue.run()
        #expect(session.sent == [finished.id])
        #expect(queue.waiting == 1)
    }

    @Test func nothingIsSentWithoutASessionButItWaits() throws {
        session.canSend = false  // the simulator, or not activated yet
        let recording = try record()
        queue.run()
        #expect(session.sent.isEmpty)
        #expect(queue.waiting == 1)
        session.canSend = true
        queue.run()
        #expect(session.sent == [recording.id])
    }

    // MARK: Recordings stuck at a duration of 0

    /// A recording whose final save failed (or the app was cut off): whole audio, but the JSON still says 0 and the
    /// WAV's sizes were never written.
    func strand(seconds: Double = 2, startedAt: Date = Date()) throws -> WatchRecording {
        let recording = WatchRecording(startedAt: startedAt, duration: 0)
        try store.save(recording)
        try synthesizedWAV(samples: Int(seconds * 16_000)).write(to: store.wavURL(recording.id))
        return recording
    }

    @Test func aRecordingStrandedAtZeroIsRepairedAndSent() throws {
        let stranded = try strand()
        #expect(queue.waiting == 0)  // invisible until now

        queue.run()

        #expect(store.load(stranded.id)?.duration == 2)
        let header = try #require(WAVFile.info(of: Data(contentsOf: store.wavURL(stranded.id))))
        #expect(header.dataSize == 64_000)  // the WAV is whole too
        #expect(session.sent == [stranded.id])
        #expect(queue.waiting == 1)
        #expect(queue.recordings.map(\.id) == [stranded.id])
    }

    @Test func aStrandedRecordingShowsAsWaitingEvenWhenNothingCanBeSentYet() throws {
        session.canSend = false
        let stranded = try strand()

        queue.run()

        #expect(queue.waiting == 1)
        #expect(session.sent.isEmpty)
        session.canSend = true
        queue.run()
        #expect(session.sent == [stranded.id])
    }

    @Test func theRecordingBeingMadeIsLeftAloneToTheLastByte() throws {
        let current = try strand()
        queue.recordingID = current.id
        let before = try Data(contentsOf: store.wavURL(current.id))

        queue.run()

        #expect(store.load(current.id)?.duration == 0)
        #expect(try Data(contentsOf: store.wavURL(current.id)) == before)
        #expect(session.sent.isEmpty)
        #expect(queue.waiting == 0)

        // Once it isn't the one being made any more, it's the queue's.
        queue.recordingID = nil
        queue.run()
        #expect(store.load(current.id)?.duration == 2)
        #expect(session.sent == [current.id])
    }

    @Test func aStrandedOneIsRepairedWhileAnotherIsBeingMade() throws {
        // After a call: the first part's save failed, the second part is recording.
        let first = try strand(seconds: 3, startedAt: Date(timeIntervalSince1970: 1_000))
        let second = try strand(seconds: 1, startedAt: Date(timeIntervalSince1970: 2_000))
        queue.recordingID = second.id

        queue.run()

        #expect(session.sent == [first.id])
        #expect(store.load(first.id)?.duration == 3)
        #expect(store.load(second.id)?.duration == 0)
        #expect(queue.waiting == 1)
    }

    @Test func aStrandedOneWithNoAudioIsRemoved() throws {
        let empty = WatchRecording(startedAt: Date(), duration: 0)
        try store.save(empty)  // no WAV at all
        let silent = try strand(seconds: 0)  // a WAV header and no samples

        queue.run()

        #expect(store.all().isEmpty)
        #expect(!FileManager.default.fileExists(atPath: store.wavURL(silent.id).path))
        #expect(session.sent.isEmpty)
    }

    @Test func aRepairedOneIsSentOnceNotEveryRun() throws {
        let stranded = try strand()
        queue.run()
        queue.run()
        queue.run()
        #expect(session.sent == [stranded.id])
    }

    @Test func anAcknowledgementForSomethingElseDeletesNothing() throws {
        let recording = try record()
        queue.run()
        queue.acknowledged(id: "../../etc")
        queue.acknowledged(id: UUID().uuidString)
        #expect(store.load(recording.id) != nil)
        #expect(queue.sent.isEmpty)
    }
}
