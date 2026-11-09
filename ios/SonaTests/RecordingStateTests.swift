import Foundation
import SonaEngine
import Testing
@testable import Sona

// What the Live Activity, the widgets and the notifications say while a recording is paused, stopped by itself or
// gone quiet, so the Lock Screen never shows a ticking "recording" that isn't.

/// A notification center that keeps what it was asked, and which ids would be up now (scheduled or showing).
nonisolated final class FakeNoticeCenter: NoticeCenter, @unchecked Sendable {
    struct Post: Equatable {
        var notice: RecordingNotice
        var delay: TimeInterval?
    }

    // Only touched on the main actor here: RecordingNotices is main-actor.
    var asked = 0
    var posts: [Post] = []
    var showing: Set<String> = []

    func askPermission() { asked += 1 }

    func post(_ notice: RecordingNotice, after delay: TimeInterval?) {
        posts.append(Post(notice: notice, delay: delay))
        showing.insert(notice.id)
    }

    func remove(_ ids: [String]) { showing.subtract(ids) }
}

struct RecordingContentStateTests {
    @Test func decodesAnActivityFromBeforePausesAndStopReasons() throws {
        // What an older build encoded: only startedAt and stoppedAt (dates as seconds since 2001, Codable's default).
        let old = Data(#"{"startedAt":783820800,"stoppedAt":783820934}"#.utf8)
        let saved = try JSONDecoder().decode(RecordingAttributes.ContentState.self, from: old)
        #expect(saved.startedAt == Date(timeIntervalSinceReferenceDate: 783_820_800))
        #expect(saved.stoppedAt == Date(timeIntervalSinceReferenceDate: 783_820_934))
        #expect(saved.pausedAt == nil)
        #expect(saved.stopReason == nil)
        #expect(saved.look(isStale: false) == .saved)

        let running = try JSONDecoder().decode(RecordingAttributes.ContentState.self, from: Data(#"{"startedAt":783820800}"#.utf8))
        #expect(running.look(isStale: false) == .recording)

        // The new fields go round.
        let start = Date(timeIntervalSinceReferenceDate: 783_820_800)
        for state in [
            RecordingAttributes.ContentState(startedAt: start, pausedAt: start.addingTimeInterval(1200)),
            RecordingAttributes.ContentState(startedAt: start, stoppedAt: start.addingTimeInterval(60), stopReason: "out of space"),
        ] {
            #expect(try JSONDecoder().decode(RecordingAttributes.ContentState.self, from: JSONEncoder().encode(state)) == state)
        }
    }

    @Test func saysWhatsTrue() {
        let start = Date(timeIntervalSinceReferenceDate: 783_820_800)
        let recording = RecordingAttributes.ContentState(startedAt: start)
        #expect(recording.look(isStale: false) == .recording)
        // No update in time: the app may be dead, so it can't claim to record.
        #expect(recording.look(isStale: true) == .notRecording)

        let paused = RecordingAttributes.ContentState(startedAt: start, pausedAt: start.addingTimeInterval(1200))
        #expect(paused.look(isStale: false) == .paused)
        #expect(paused.look(isStale: true) == .notRecording)

        // Once it's over the length is final, stale or not.
        let saved = RecordingAttributes.ContentState(startedAt: start, stoppedAt: start.addingTimeInterval(3600))
        #expect(saved.look(isStale: true) == .saved)
        let stopped = RecordingAttributes.ContentState(
            startedAt: start, stoppedAt: start.addingTimeInterval(1200), stopReason: "out of space")
        #expect(stopped.look(isStale: false) == .stopped(reason: "out of space"))
    }
}

@MainActor
struct RecordingNoticesTests {
    @Test func schedulesOnPauseTakesItBackAndSaysASelfStopAtOnce() {
        let center = FakeNoticeCenter()
        let notices = RecordingNotices(center: center)

        notices.recordingStarted(canAsk: true)
        #expect(center.asked == 1)
        notices.recordingStarted(canAsk: false)  // started from the Lock Screen: nowhere to show the question
        #expect(center.asked == 1)

        notices.paused()
        notices.paused()  // the mic saying so again: still one notice
        #expect(center.posts == [.init(notice: .paused, delay: RecordingNotices.pauseGrace)])
        #expect(center.showing == [RecordingNotice.pausedID])

        notices.resumed()
        #expect(center.showing.isEmpty)

        notices.paused()  // a new pause is told again
        #expect(center.posts.count == 2)
        notices.stopped()
        #expect(center.showing.isEmpty)
        #expect(center.posts.count == 2)  // he stopped it himself: nothing to say

        notices.paused()
        notices.stopped(because: "This iPhone is out of space.")
        #expect(center.posts.last == .init(notice: .stopped("This iPhone is out of space."), delay: nil))
        #expect(center.showing == [RecordingNotice.stoppedID])
    }
}

/// PhoneRecorder with silence from the file source standing in for the mic, and the mic's state calls made by hand
/// from a queue of its own, as MicCapture makes them when a call takes the mic and gives it back.
@MainActor
@Suite(.serialized)
struct RecordingPauseTests {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("spool-\(UUID().uuidString)", isDirectory: true)
    let micQueue = DispatchQueue(label: "test.mic")

    /// The widgets' status in a UserDefaults suite of the test's own, counting reloads.
    final class TestStatus {
        let defaults = UserDefaults(suiteName: "sona-tests-\(UUID().uuidString)")!
        var reloads = 0

        var store: WidgetStatus.Store {
            WidgetStatus.Store(
                load: {
                    guard let data = self.defaults.data(forKey: SharedStatus.key) else { return SharedStatus() }
                    return (try? JSONDecoder().decode(SharedStatus.self, from: data)) ?? SharedStatus()
                },
                save: { self.defaults.set(try? JSONEncoder().encode($0), forKey: SharedStatus.key) },
                reload: { self.reloads += 1 })
        }

        var saved: SharedStatus { store.load() }
    }

    /// The handlers the recorder gave its source, so the test can speak for the mic. Nonisolated: the source factory
    /// that keeps them isn't on the main actor.
    nonisolated final class Handed: @unchecked Sendable {
        private let lock = NSLock()
        private var kept: CaptureHandlers?
        var handlers: CaptureHandlers? { lock.withLock { kept } }
        func keep(_ handlers: CaptureHandlers) { lock.withLock { kept = handlers } }
    }

    func recorder(_ status: TestStatus, _ center: FakeNoticeCenter, _ handed: Handed) -> PhoneRecorder {
        let recorder = PhoneRecorder(
            spool: Spool(dir: dir), showsActivity: false, status: status.store, notices: RecordingNotices(center: center)
        ) { handlers in
            handed.keep(handlers)
            return FileAudioSource(file: nil, handlers: handlers)
        }
        recorder.checkpointSeconds = 2
        return recorder
    }

    func micSays(_ state: CaptureState, _ handed: Handed) {
        guard let handlers = handed.handlers else { return }
        micQueue.async { handlers.state(state, nil) }
    }

    /// Polls, so a busy machine slows the test down instead of failing it.
    func waitUntil(seconds: Double = 10, _ condition: () -> Bool) async {
        let deadline = Date().addingTimeInterval(seconds)
        while !condition(), Date() < deadline { try? await Task.sleep(for: .milliseconds(20)) }
    }

    @Test func aPauseShowsEverywhereAndTheMicComingBackUndoesIt() async throws {
        let status = TestStatus(), center = FakeNoticeCenter(), handed = Handed()
        let recorder = recorder(status, center, handed)
        try await recorder.start()
        let started = try #require(recorder.startedAt)
        #expect(status.saved.recordingSince == started)
        #expect(status.saved.pausedAt == nil)
        #expect(recorder.pausedAt == nil)
        let reloads = status.reloads

        // A call takes the mic.
        let before = Date()
        micSays(.interrupted, handed)
        await waitUntil { recorder.pausedAt != nil }
        let pausedAt = try #require(recorder.pausedAt)
        #expect(pausedAt >= before)
        #expect(recorder.isRecording)  // still the same recording: it carries on when the mic's back
        #expect(recorder.lastError != nil)
        #expect(status.saved.recordingSince == started)
        #expect(status.saved.pausedAt == pausedAt)  // the widgets stop counting and say "paused"
        #expect(status.reloads == reloads + 1)
        #expect(center.posts == [.init(notice: .paused, delay: RecordingNotices.pauseGrace)])
        #expect(center.showing == [RecordingNotice.pausedID])

        // Retries that miss say so again, then that it needs the app: still the one pause and the one notice.
        micSays(.interrupted, handed)
        micSays(.needsResume, handed)
        await waitUntil { recorder.lastError?.contains("Open Sona") == true }
        #expect(recorder.lastError?.contains("Open Sona") == true)
        #expect(recorder.pausedAt == pausedAt)
        #expect(center.posts.count == 1)
        #expect(status.reloads == reloads + 1)

        // The call's over and the mic is back.
        micSays(.running, handed)
        await waitUntil { recorder.pausedAt == nil }
        #expect(recorder.pausedAt == nil)
        #expect(recorder.lastError == nil)
        #expect(status.saved.recordingSince == started)
        #expect(status.saved.pausedAt == nil)
        #expect(center.showing.isEmpty)  // the notice taken back, scheduled or showing

        // Paused again, then he stops it: the notice goes, and nothing says it's recording.
        micSays(.interrupted, handed)
        await waitUntil { recorder.pausedAt != nil }
        #expect(center.showing == [RecordingNotice.pausedID])
        await recorder.stop()
        #expect(!recorder.isRecording)
        #expect(recorder.pausedAt == nil)
        #expect(center.showing.isEmpty)
        #expect(center.posts.count == 2)  // the two pauses; a stop he made needs no notice
        #expect(status.saved.recordingSince == nil)
        #expect(status.saved.pausedAt == nil)

        // A late word from the mic of a recording that's over changes nothing.
        micSays(.interrupted, handed)
        try await Task.sleep(for: .milliseconds(200))
        #expect(recorder.pausedAt == nil)
        #expect(center.posts.count == 2)
        try? FileManager.default.removeItem(at: dir)
    }

    @Test func aRecordingThatStopsByItselfSaysWhy() async throws {
        let status = TestStatus(), center = FakeNoticeCenter(), handed = Handed()
        let recorder = recorder(status, center, handed)
        var finished: [String] = []
        recorder.onFinished = { finished.append($0) }
        try await recorder.start()
        try await Task.sleep(for: .seconds(0.8))  // over half a second, so it's kept
        micSays(.interrupted, handed)
        await waitUntil { recorder.pausedAt != nil }
        #expect(center.showing == [RecordingNotice.pausedID])

        await recorder.stop(because: .outOfSpace)
        #expect(!recorder.isRecording)
        #expect(recorder.pausedAt == nil)
        #expect(recorder.lastError == StopReason.outOfSpace.message)
        #expect(finished.count == 1)  // what it had is kept
        // The pause notice taken back, and why it stopped said at once.
        #expect(center.posts.last == .init(notice: .stopped(StopReason.outOfSpace.notice), delay: nil))
        #expect(center.showing == [RecordingNotice.stoppedID])
        #expect(status.saved.recordingSince == nil)
        #expect(status.saved.pausedAt == nil)

        await recorder.stop(because: .lowSpace)  // not recording: nothing happens
        #expect(center.posts.count == 2)
        try? FileManager.default.removeItem(at: dir)
    }
}
