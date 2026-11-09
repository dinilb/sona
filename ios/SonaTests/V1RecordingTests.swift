import Foundation
import SonaEngine
import Testing
@testable import Sona

/// The recorder's v1 decisions as plain functions: the mic watchdog, the mic question from the background, the Live
/// Activity's life under a long recording, and the widgets' word that the app is alive.
struct V1RecordingDecisionTests {
    @Test func theWatchdogFiresOnlyWhileHearing() {
        #expect(MicWatchdog.stalled(age: 6, hearing: true))
        #expect(!MicWatchdog.stalled(age: 4, hearing: true))
        // During a call or a restart's backoff no audio is expected: firing then would reset the backoff.
        #expect(!MicWatchdog.stalled(age: 600, hearing: false))
    }

    @Test func comingBackRebuildsAnEngineThatSaysItRunsButHearsNothing() {
        #expect(!MicWatchdog.restartOnActive(hearing: true, engineRunning: true, age: 0.2))
        #expect(MicWatchdog.restartOnActive(hearing: true, engineRunning: true, age: 30))  // the old check missed this
        #expect(MicWatchdog.restartOnActive(hearing: true, engineRunning: false, age: 0.2))
        #expect(MicWatchdog.restartOnActive(hearing: false, engineRunning: true, age: 0.2))
    }

    @Test func theMicIsAskedForOnlyOnScreen() {
        #expect(PhoneRecorder.micStep(granted: true, denied: false, inBackground: true) == .go)
        #expect(PhoneRecorder.micStep(granted: false, denied: true, inBackground: false) == .denied)
        #expect(PhoneRecorder.micStep(granted: false, denied: false, inBackground: false) == .ask)
        // The Lock Screen control or Siri before the mic was ever asked: no question can show, so it says what to do.
        #expect(PhoneRecorder.micStep(granted: false, denied: false, inBackground: true) == .notAsked)
        let notAsked = RecordingError.micNotAsked.errorDescription ?? ""
        #expect(notAsked.contains("tap Record"))
        #expect(!notAsked.contains("Settings"))  // Settings has no switch for a mic never asked for
    }

    @Test func anActivityEndedUnderALiveRecordingIsLost() {
        #expect(ActivityLife.lost(ended: true, id: "a", current: "a", recording: true))
        // The app's own end clears the id first; a renewal swaps it.
        #expect(!ActivityLife.lost(ended: true, id: "a", current: nil, recording: true))
        #expect(!ActivityLife.lost(ended: true, id: "a", current: "b", recording: true))
        #expect(!ActivityLife.lost(ended: true, id: "a", current: "a", recording: false))
        #expect(!ActivityLife.lost(ended: false, id: "a", current: "a", recording: true))
    }

    @Test func theActivityIsRenewedBeforeEightHoursOnlyOnScreen() {
        let almost = 7 * 3600 + 56 * 60.0
        #expect(ActivityLife.needsRenewal(age: almost, appActive: true))
        #expect(!ActivityLife.needsRenewal(age: almost, appActive: false))  // a new one can't be asked for from there
        #expect(!ActivityLife.needsRenewal(age: 7 * 3600, appActive: true))
        #expect(ActivityLife.renewAfter < ActivityLife.systemLimit)
    }

    @Test func theWidgetsHearTheAppIsAliveEveryFewMinutes() {
        let start = Date(timeIntervalSince1970: 1_793_000_000)
        let started = PhoneRecorder.status(SharedStatus(), recordingSince: start, pausedAt: nil, alive: false, now: start)
        #expect(started.recordingSince == start)
        #expect(started.aliveAt == start)

        // A heartbeat a minute later changes nothing (no reload); five minutes on it moves the word on.
        let soon = PhoneRecorder.status(started, recordingSince: start, pausedAt: nil, alive: true, now: start + 60)
        #expect(soon == started)
        let later = PhoneRecorder.status(started, recordingSince: start, pausedAt: nil, alive: true, now: start + 300)
        #expect(later.aliveAt == start + 300)

        // A pause isn't a heartbeat; a stop clears it all.
        let paused = PhoneRecorder.status(later, recordingSince: start, pausedAt: start + 400, alive: false, now: start + 400)
        #expect(paused.aliveAt == start + 300)
        #expect(paused.pausedAt == start + 400)
        let stopped = PhoneRecorder.status(paused, recordingSince: nil, pausedAt: nil, alive: false, now: start + 500)
        #expect(stopped.recordingSince == nil)
        #expect(stopped.aliveAt == nil)
    }

    @Test func aRecordingTheAppStoppedVouchingForGoesStale() throws {
        let start = Date(timeIntervalSince1970: 1_793_000_000)
        var status = SharedStatus(recordingSince: start)
        status.aliveAt = start + 600
        let staleAt = try #require(status.staleAt)
        #expect(staleAt == start + 600 + SharedStatus.staleAfter)
        #expect(!status.isStale(at: staleAt - 1))
        #expect(status.isStale(at: staleAt))
        #expect(SharedStatus().staleAt == nil)
        #expect(!SharedStatus().isStale(at: .distantFuture))
        // A status saved by an older build (no aliveAt) still decodes, and goes stale from its start.
        let old = try JSONDecoder().decode(SharedStatus.self, from: Data(#"{"recordingSince":783820800,"waiting":0}"#.utf8))
        #expect(old.aliveAt == nil)
        #expect(old.staleAt == old.recordingSince.map { $0 + SharedStatus.staleAfter })
    }

    @Test func theWidgetTimelineHasBothMidnightsAndTheStaleMoment() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try #require(TimeZone(identifier: "Australia/Brisbane"))
        let now = try #require(calendar.date(from: DateComponents(year: 2026, month: 11, day: 2, hour: 9, minute: 41)))
        let today = calendar.startOfDay(for: now)
        let note = SharedStatus(latestTitle: "Budget", latestAt: now)
        // "9:41 am", then "yesterday" at the next midnight, then a fixed date at the one after (which never goes stale).
        #expect(note.timelineDates(now: now, calendar: calendar) == [now, today + 86_400, today + 2 * 86_400])

        var recording = SharedStatus(recordingSince: now)
        recording.aliveAt = now
        #expect(recording.timelineDates(now: now, calendar: calendar) == [now, now + SharedStatus.staleAfter])
        #expect(SharedStatus().timelineDates(now: now, calendar: calendar) == [now])
    }
}

/// The "still recording" notice when iOS ends the Live Activity under a recording.
@MainActor
struct V1RecordingNoticeTests {
    @Test func anActivitySchedulesTheEightHourNoticeAndAStopTakesItBack() {
        let center = FakeNoticeCenter()
        let notices = RecordingNotices(center: center)
        notices.activityStarted()
        #expect(center.posts == [.init(notice: .stillRecording, delay: ActivityLife.systemLimit)])
        #expect(center.showing == [RecordingNotice.stillRecordingID])

        // Swiped away while it records: said at once.
        notices.activityLost()
        #expect(center.posts.last == .init(notice: .stillRecording, delay: nil))

        notices.stopped()
        #expect(center.showing.isEmpty)
    }

    @Test func theAppsOwnEndTakesItBack() {
        let center = FakeNoticeCenter()
        let notices = RecordingNotices(center: center)
        notices.activityStarted()
        notices.activityGone()
        #expect(center.showing.isEmpty)
        #expect(center.posts.count == 1)
    }
}

/// Two stops queued in the same turn (the Stop intent and a tap, the disk watcher and a tap) close the recording once,
/// and the recorder can record again after.
@Suite(.serialized) @MainActor
struct V1RecordingStopTests {
    @Test func twoStopsInOneTurnCloseItOnce() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("spool-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let recorder = PhoneRecorder(spool: Spool(dir: dir), showsActivity: false) { handlers in
            FileAudioSource(file: nil, handlers: handlers)
        }
        var finished: [String] = []
        recorder.onFinished = { finished.append($0) }
        try await recorder.start()
        try await Task.sleep(for: .seconds(0.8))  // over half a second, so it's kept

        let first = Task { await recorder.stop() }
        let second = Task { await recorder.stop(because: .lowSpace) }
        await first.value
        await second.value
        #expect(finished.count == 1)
        #expect(!recorder.isRecording)
        #expect(recorder.lastError == nil)  // the second stop found nothing recording: no "stopped" message

        try await recorder.start()
        #expect(recorder.isRecording)
        try await Task.sleep(for: .seconds(0.8))
        await recorder.stop()
        #expect(finished.count == 2)
        #expect(Set(finished).count == 2)
    }
}
