import AVFoundation

/// The mic taken away and given back: a call, Siri, an alarm.
nonisolated enum Interruption: Equatable, Sendable {
    case began
    case ended(shouldResume: Bool)

    /// Reads the userInfo of `AVAudioSession.interruptionNotification`; nil if it isn't one.
    init?(userInfo: [AnyHashable: Any]?) {
        guard let raw = userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
            let type = AVAudioSession.InterruptionType(rawValue: raw)
        else { return nil }
        switch type {
        case .began:
            self = .began
        case .ended:
            let options = userInfo?[AVAudioSessionInterruptionOptionKey] as? UInt ?? 0
            self = .ended(shouldResume: AVAudioSession.InterruptionOptions(rawValue: options).contains(.shouldResume))
        @unknown default:
            return nil
        }
    }
}

/// What to do when a call or Siri takes the mic in the middle of a recording. He never asked to stop, so the
/// recording is saved the moment the mic goes (it's queued for the iPhone like any other). When the mic comes back
/// soon with Sona on screen, a new one starts, whether or not the system says "should resume": a meeting with a quick
/// call in the middle becomes two recordings, not 6 minutes. Otherwise it's left to him: watchOS won't start the mic
/// for an app in the background (Apple, forums thread 750432), and a recording that starts by itself long after
/// would be a surprise.
nonisolated struct InterruptionPolicy {
    enum Action: Equatable {
        case nothing
        /// Finish and save the recording as it is now, and wait for the interruption to end.
        case saveAndWait
        /// The interruption is over: start a new recording.
        case startNewRecording
        /// The interruption is over, but too late or off screen to start again by itself: let the mic go, and tell
        /// him (`tell`) unless the notification scheduled when it went has already done so.
        case leaveItToHim(tell: Bool)
    }

    /// An interruption that ends later than this isn't a quick call in the middle of a meeting any more.
    static let resumeWindow: TimeInterval = 2 * 60
    /// If nothing has taken the mic back by this long after it went, a notification says so. It's scheduled when
    /// the mic goes, so it fires even if the app is suspended before the interruption ends.
    static let notifyAfter: TimeInterval = 30

    /// When the mic went, while a new recording is waiting for it to come back.
    private(set) var waitingSince: Date?

    var isWaiting: Bool { waitingSince != nil }

    /// `onScreen`: Sona is in front on the watch (the scene is active), the only time the mic may start again.
    mutating func handle(_ event: Interruption, isRecording: Bool, now: Date, onScreen: Bool = true) -> Action {
        switch event {
        case .began:
            // Nothing to save when nothing was recording; a second "began" during a wait changes nothing.
            guard isRecording else { return .nothing }
            waitingSince = now
            return .saveAndWait
        case .ended:
            guard let since = waitingSince else { return .nothing }
            waitingSince = nil
            guard !isRecording else { return .nothing }
            let gone = now.timeIntervalSince(since)
            if onScreen, gone <= Self.resumeWindow { return .startNewRecording }
            return .leaveItToHim(tell: gone < Self.notifyAfter)
        }
    }

    /// A recording is going again (started by hand, or the restart worked): nothing is waiting any more.
    mutating func stopWaiting() { waitingSince = nil }
}

/// The watch's free storage: a recording is about 14 MB an hour (115 MB if it fell back to a WAV).
nonisolated enum DiskPolicy {
    /// No recording starts with less than this free.
    static let minimumToStart: Int64 = 100_000_000
    /// A recording stops, saved, when the watch is down to this.
    static let minimumToContinue: Int64 = 50_000_000
    /// How often a recording checks. A minute of audio is about 2 MB, so the margin above is plenty.
    static let checkEvery: Duration = .seconds(60)

    /// An unknown amount (nil) never stops anything.
    static func canStart(freeBytes: Int64?) -> Bool { freeBytes.map { $0 >= minimumToStart } ?? true }
    static func mustStop(freeBytes: Int64?) -> Bool { freeBytes.map { $0 < minimumToContinue } ?? false }
}

/// Is the recorder still writing? Wrist-down recording has never been watched on a real watch, and a recorder can die
/// with no callback (media services reset, the app suspended). The timers on the screen and the watch face count
/// from the start whatever happens, so without this he'd believe in 40 minutes when the audio stopped at 2.
nonisolated enum HealthPolicy {
    /// Under this much time since the last check (a quick wrist raise), nothing is judged.
    static let judgeAfter: TimeInterval = 20
    /// Each healthy check pushes a "may have stopped" notification this far ahead. If the checks stop (the app was
    /// suspended, killed or crashed), it fires: no code of ours runs then to say so.
    static let watchdogAfter: TimeInterval = 3 * 60
    /// A recording this long gets a "still recording" nudge: the mic indicator is small, and one left on runs until
    /// the battery or the storage gives out. It isn't stopped: a real lecture runs that long.
    static let stillRecordingAfter: TimeInterval = 2 * 60 * 60

    /// True if less than half the time that went by since the last check was recorded.
    static func stalled(wall: TimeInterval, audio: TimeInterval) -> Bool {
        wall >= judgeAfter && audio < wall / 2
    }
}

/// A notification scheduled ahead while recording, each under its own identifier so neither replaces the other or
/// the stop notification.
nonisolated enum RecordingReminder: CaseIterable, Sendable {
    /// Fires only if the health checks stop.
    case mayHaveStopped
    /// Fires once a recording has run `HealthPolicy.stillRecordingAfter`.
    case stillRecording

    var identifier: String {
        switch self {
        case .mayHaveStopped: "sona.mayHaveStopped"
        case .stillRecording: "sona.stillRecording"
        }
    }

    var title: String {
        switch self {
        case .mayHaveStopped: "Sona may have stopped recording"
        case .stillRecording: "Sona is still recording"
        }
    }

    var body: String {
        switch self {
        case .mayHaveStopped: "Open Sona to check. What was recorded is saved."
        case .stillRecording: "It's been recording for 2 hours. Open Sona to stop it if you're done."
        }
    }
}

/// A recording that stopped without him asking and isn't going again, for the notification.
nonisolated enum UnexpectedStop: Equatable, Sendable {
    /// A call or Siri took the mic and nothing has given it back yet.
    case interrupted
    /// The mic came back but the new recording wouldn't start.
    case couldNotResume
    case lowStorage
    /// The recorder finished or failed by itself.
    case recorderStopped

    static let title = "Sona stopped recording"

    var body: String {
        switch self {
        case .interrupted: "A call or Siri took the mic. Your note so far is saved. Open Sona to record again."
        case .couldNotResume: "Sona couldn't carry on after the call. Your note so far is saved. Open Sona to record again."
        case .lowStorage: "The watch is nearly out of storage. Your note is saved. Free up some space to record again."
        case .recorderStopped: "The recording stopped on its own. What was recorded is saved. Open Sona to record again."
        }
    }
}
