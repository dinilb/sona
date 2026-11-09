import ActivityKit
import Foundation

/// The Live Activity shown while the iPhone records: on the Lock Screen and in the Dynamic Island.
/// The timer counts itself (`Text(timerInterval:)`). The app updates it when the recording starts, pauses, carries on
/// and stops, and once a minute in between: each update goes stale 90 s on, so if the app dies (or iOS suspends it
/// while a call has the mic) the activity stops counting and says it isn't recording.
nonisolated struct RecordingAttributes: ActivityAttributes {
    /// The new fields are optional, so an activity an older build started still decodes.
    nonisolated struct ContentState: Codable, Hashable {
        /// When this recording started.
        var startedAt: Date
        /// Set once it's stopped: the activity says "saved" (or why it stopped) and goes.
        var stoppedAt: Date?
        /// Set while the mic is paused (a call, Siri, or it hasn't come back after one): the length stops counting.
        var pausedAt: Date?
        /// Why it stopped by itself, short and lowercase ("out of space"); nil when it was stopped and saved.
        var stopReason: String?
        /// The last few seconds of loudness, oldest first, 0...100 (`ActivityWave`): the waveform. Nil before the
        /// first one (and in an activity an older build started).
        var levels: [UInt8]?
    }

    /// "iPhone" for now; kept so a watch-started recording could say so later.
    var source: String = "iPhone"
}

nonisolated extension RecordingAttributes.ContentState {
    /// What the activity says.
    enum Look: Equatable {
        case recording
        /// The mic is paused; the recording carries on when it's back.
        case paused
        /// The app hasn't updated it in time: it may have died, so it can't claim to be recording.
        case notRecording
        case saved
        case stopped(reason: String)
    }

    /// `isStale`: the system's word that the last update's stale date has passed.
    func look(isStale: Bool) -> Look {
        if stoppedAt != nil { return stopReason.map { .stopped(reason: $0) } ?? .saved }
        if isStale { return .notRecording }
        return pausedAt == nil ? .recording : .paused
    }
}

/// The Live Activity's waveform. A Live Activity can't animate by itself, so the app sends the last few seconds of
/// loudness with each update, and the bars change when the next one lands (`PhoneRecorder.waveSeconds`).
nonisolated enum ActivityWave {
    /// Bars on the Lock Screen and in the expanded island: 4 s at the recorder's 10 levels a second, so each update
    /// shows seconds the last one didn't.
    static let count = 40

    /// The newest `count` levels (0...1), oldest first, as whole percents: small enough for an update (4 KB at most).
    static func encode(_ levels: [Float]) -> [UInt8] {
        levels.suffix(count).map { UInt8((min(1, max(0, $0.isFinite ? $0 : 0)) * 100).rounded()) }
    }

    /// Nothing heard: every level under the 2% the bars draw as faint dots.
    static func isQuiet<Levels: Collection<UInt8>>(_ levels: Levels) -> Bool {
        levels.allSatisfy { $0 < 3 }
    }

    /// `bars` heights (0...1) from what an update carried: the newest on the right, padded with silence on the left
    /// when there's less (the first seconds), the newest `bars` when there's more (the compact island's few: half a
    /// second of speech still rises and falls, where the loudest of each slice would be all tall bars).
    static func heights(_ levels: [UInt8]?, bars: Int) -> [Double] {
        guard bars > 0 else { return [] }
        let values = (levels ?? []).suffix(bars).map { Double(min($0, 100)) / 100 }
        return Array(repeating: 0, count: bars - values.count) + values
    }
}
