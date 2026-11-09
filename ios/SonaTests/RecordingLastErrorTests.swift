import Foundation
import SonaEngine
import Testing
@testable import Sona

// What the screen says under the Record button once a recording is over. These use RecordingPauseTests's stand-ins
// for the mic (RecordingStateTests.swift), so they run on the same silent file source.

extension RecordingPauseTests {
    @Test func aNormalStopClearsWhatAPauseLeftOnScreen() async throws {
        let status = TestStatus(), center = FakeNoticeCenter(), handed = Handed()
        let recorder = recorder(status, center, handed)
        try await recorder.start()

        // A call takes the mic, and the screen says so.
        micSays(.interrupted, handed)
        await waitUntil { recorder.pausedAt != nil }
        #expect(recorder.lastError?.contains("Paused") == true)
        // It doesn't come back by itself.
        micSays(.needsResume, handed)
        await waitUntil { recorder.lastError?.contains("Open Sona") == true }
        #expect(recorder.lastError?.contains("Open Sona") == true)

        // He stops it: nothing is wrong any more, so nothing stays under the button.
        await recorder.stop()
        #expect(!recorder.isRecording)
        #expect(recorder.pausedAt == nil)
        #expect(recorder.lastError == nil)
        try? FileManager.default.removeItem(at: dir)
    }

    @Test func aStopWithAReasonKeepsItsOwnMessageUntilTheNextStart() async throws {
        let status = TestStatus(), center = FakeNoticeCenter(), handed = Handed()
        let recorder = recorder(status, center, handed)
        try await recorder.start()
        try await Task.sleep(for: .seconds(0.8))  // over half a second, so it's kept
        micSays(.interrupted, handed)
        await waitUntil { recorder.pausedAt != nil }
        #expect(recorder.lastError != nil)

        // It stops by itself: its own message replaces the pause's, and stays.
        await recorder.stop(because: .writeFailed)
        #expect(recorder.lastError == StopReason.writeFailed.message)

        // The next recording starts clean, and a normal stop leaves it clean.
        try await recorder.start()
        #expect(recorder.isRecording)
        #expect(recorder.lastError == nil)
        await recorder.stop()
        #expect(recorder.lastError == nil)
        try? FileManager.default.removeItem(at: dir)
    }

    @Test func aStopWhenNothingIsRecordingLeavesAMessageAlone() async throws {
        let status = TestStatus(), center = FakeNoticeCenter(), handed = Handed()
        let recorder = recorder(status, center, handed)
        try await recorder.start()
        try await Task.sleep(for: .seconds(0.8))
        await recorder.stop(because: .lowSpace)
        #expect(recorder.lastError == StopReason.lowSpace.message)

        // Stop again with nothing recording: the message about why it stopped is still true.
        await recorder.stop()
        #expect(recorder.lastError == StopReason.lowSpace.message)
        try? FileManager.default.removeItem(at: dir)
    }
}
