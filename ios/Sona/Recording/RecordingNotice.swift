import Foundation
import NotesKit
import UserNotifications

/// One notification about a recording.
nonisolated struct RecordingNotice: Equatable, Sendable {
    var id: String
    var title: String
    var body: String

    static let pausedID = "com.dinilb.sona.recording.paused"
    static let stoppedID = "com.dinilb.sona.recording.stopped"
    static let stillRecordingID = "com.dinilb.sona.recording.still"

    /// Its Live Activity is gone (swiped away, or iOS's 8-hour limit) but the mic still records: nothing on the Lock
    /// Screen says so any more.
    static let stillRecording = RecordingNotice(
        id: stillRecordingID, title: "Sona is still recording",
        body: "Open Sona or say \"Stop Sona\" to stop it. Everything so far is saved as it goes.")

    /// The mic has been paused a while (a call, Siri) and may not come back by itself.
    static let paused = RecordingNotice(
        id: pausedID, title: "Sona stopped recording", body: "Open Sona to carry on. What it recorded so far is safe.")

    /// It stopped by itself: `reason` says why, as a sentence.
    static func stopped(_ reason: String) -> RecordingNotice {
        RecordingNotice(id: stoppedID, title: "Sona stopped recording", body: reason)
    }
}

/// The few notification-center calls the notices make, so tests can stand in a fake.
nonisolated protocol NoticeCenter: AnyObject, Sendable {
    /// Asks to show notifications. Only the first time shows a question; it never waits for the answer.
    func askPermission()
    /// Shows `notice` after `delay` seconds (nil: now), in place of any with the same id.
    func post(_ notice: RecordingNotice, after delay: TimeInterval?)
    /// Takes back notices with these ids, whether they're still to come or already showing.
    func remove(_ ids: [String])
}

/// Tells him, outside the app, when a recording stops hearing anything. The Lock Screen can't be trusted with that:
/// iOS may suspend the app while a call has the mic, so nothing in the app runs until he opens it. A notification
/// scheduled the moment the mic pauses fires anyway, unless the mic comes back first.
@MainActor
final class RecordingNotices {
    /// How long the mic is paused before he's told: a short pause (an alarm, a quick Siri) carries on by itself first.
    static let pauseGrace: TimeInterval = 20

    private let center: any NoticeCenter
    /// The paused notice is scheduled (or showing): one per pause, however often the mic says it's still paused.
    private var pauseNoticeOut = false
    /// When the recording's Live Activity reaches iOS's 8-hour limit; nil with none up.
    private var activityEndsAt: Date?
    /// A call or Siri has the mic: iOS may suspend the app until it's back.
    private var micPaused = false

    init(center: any NoticeCenter) {
        self.center = center
    }

    /// A recording started. `canAsk`: the app is on screen, so the permission question can show (a recording started
    /// from the Lock Screen asks next time instead). Recording never waits for it.
    func recordingStarted(canAsk: Bool) {
        if canAsk { center.askPermission() }
        takeBackPauseNotice()  // left from an earlier recording
    }

    func paused(at now: Date = Date()) {
        if !micPaused {
            micPaused = true
            scheduleStillRecording(now: now)
        }
        guard !pauseNoticeOut else { return }
        pauseNoticeOut = true
        center.post(.paused, after: Self.pauseGrace)
    }

    func resumed() {
        // The app runs again, so it says it itself if iOS ends the activity. Not once the activity is gone: then the
        // notice showing is true.
        if micPaused, activityEndsAt != nil { center.remove([RecordingNotice.stillRecordingID]) }
        micPaused = false
        takeBackPauseNotice()
    }

    /// It stopped. `reason`: it stopped by itself, and that's said at once; nil: he stopped it.
    func stopped(because reason: String? = nil) {
        micPaused = false
        activityEndsAt = nil
        takeBackPauseNotice()
        center.remove([RecordingNotice.stillRecordingID])
        if let reason { center.post(.stopped(reason), after: nil) }
    }

    /// A Live Activity went up for the recording; iOS ends it 8 hours on. While the mic hears, the app is running then
    /// and says so itself (`activityLost`), so the notice is only scheduled ahead while the mic is paused, when iOS may
    /// have suspended the app. Scheduled from the start, it fired 8 hours on after iOS killed Sona mid-recording,
    /// saying it still recorded when nothing did. A new activity (renewed, or back after a swipe) moves it on.
    func activityStarted(at now: Date = Date()) {
        activityEndsAt = now + ActivityLife.systemLimit
        center.remove([RecordingNotice.stillRecordingID])
        if micPaused { scheduleStillRecording(now: now) }
    }

    /// iOS ended the activity under a live recording: said now.
    func activityLost() {
        activityEndsAt = nil
        center.post(.stillRecording, after: nil)
    }

    /// The recording's activity was ended by the app (the recording stopped), or the app just launched, so nothing
    /// records (one that died with the mic paused left its 8-hour notice scheduled): nothing left to say.
    func activityGone() {
        activityEndsAt = nil
        center.remove([RecordingNotice.stillRecordingID])
    }

    /// "Still recording" when the activity ends, for an app iOS may not run then.
    private func scheduleStillRecording(now: Date) {
        guard let activityEndsAt else { return }
        center.post(.stillRecording, after: max(1, activityEndsAt.timeIntervalSince(now)))
    }

    private func takeBackPauseNotice() {
        pauseNoticeOut = false
        center.remove([RecordingNotice.pausedID])
    }
}

/// UNUserNotificationCenter. Every call goes to one serial queue of its own: the center can block its caller for many
/// seconds when its daemon is busy (23 s measured on a simulator just booted), and on the main actor that froze the app
/// before it showed it was recording. One serial queue keeps them in order, so a pause notice is never taken back before
/// it's posted. Nonisolated, so the completion handlers handed to it are too: iOS calls them on its own queue, where a
/// closure isolated to the main actor would crash.
nonisolated final class SystemNoticeCenter: NoticeCenter {
    private let queue = DispatchQueue(label: "com.dinilb.sona.notices", qos: .utility)

    func askPermission() {
        queue.async {
            UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, error in
                if let error { Log.note("recording: couldn't ask to notify: \(Log.describe(error))") }
            }
        }
    }

    func post(_ notice: RecordingNotice, after delay: TimeInterval?) {
        let content = UNMutableNotificationContent()
        content.title = notice.title
        content.body = notice.body
        content.sound = .default
        // nil delivers it now; a time trigger needs at least a moment.
        let trigger = delay.map { UNTimeIntervalNotificationTrigger(timeInterval: max(1, $0), repeats: false) }
        let request = UNNotificationRequest(identifier: notice.id, content: content, trigger: trigger)
        queue.async {
            UNUserNotificationCenter.current().add(request) { error in
                if let error { Log.note("recording: notice not posted: \(Log.describe(error))") }
            }
        }
    }

    func remove(_ ids: [String]) {
        queue.async {
            let center = UNUserNotificationCenter.current()
            center.removePendingNotificationRequests(withIdentifiers: ids)
            center.removeDeliveredNotifications(withIdentifiers: ids)
        }
    }
}
