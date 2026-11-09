import Foundation
import Testing
@testable import SonaWatch

@MainActor
struct HealthClockTests {
    final class Seconds {
        var value: TimeInterval = 0
    }

    /// The watch's time is set an hour forward between two checks while the recorder keeps writing: the check runs on
    /// a clock that setting the time doesn't move, so the recording goes on.
    @Test func aClockSetForwardIsNotAStall() async throws {
        let rig = try Rig()
        let monotonic = Seconds()
        rig.recorder.clock = { monotonic.value }
        await rig.recorder.start()
        let capture = try #require(rig.mic.captures.first)

        rig.world.clock += 60 * 60 + 60
        monotonic.value += 60
        capture.currentTime = 60
        rig.recorder.checkAlive()

        #expect(rig.recorder.isRecording)
    }

    /// The same clock still catches a recorder that stopped writing, whatever the wall clock says.
    @Test func aStallIsStillCaughtOnThatClock() async throws {
        let rig = try Rig()
        let monotonic = Seconds()
        rig.recorder.clock = { monotonic.value }
        await rig.recorder.start()
        let capture = try #require(rig.mic.captures.first)

        monotonic.value += 60
        capture.currentTime = 2
        rig.recorder.checkAlive()

        #expect(!rig.recorder.isRecording)
    }

    @Test func theRealClockMovesOn() async throws {
        let before = WatchRecorder.continuousSeconds()
        try await Task.sleep(for: .milliseconds(20))
        #expect(WatchRecorder.continuousSeconds() > before)
    }
}
