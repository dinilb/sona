import Foundation
import SonaEngine
import Testing
@testable import Sona

/// A launch after the app died mid-recording: the "still recording" notice that recording scheduled 8 hours on (or
/// already showed) is taken back, so it never says the mic is on when nothing records. Uses RecordingStateTests.swift's
/// FakeNoticeCenter.
@MainActor
struct V1FixRecordingLaunchTests {
    @Test func aLaunchTakesBackTheStillRecordingNoticeOfOneThatDied() {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("spool-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let center = FakeNoticeCenter()
        // What the process that died left behind: its 8-hour notice, scheduled.
        center.post(.stillRecording, after: ActivityLife.systemLimit)
        #expect(center.showing == [RecordingNotice.stillRecordingID])

        _ = PhoneRecorder(spool: Spool(dir: dir), showsActivity: false, notices: RecordingNotices(center: center))
        #expect(center.showing.isEmpty)
        #expect(center.posts.count == 1)  // nothing new said
    }
}
