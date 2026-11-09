#if DEBUG
import Foundation

// Sample states for the previews (WidgetPreviews.swift) and the PNG snapshots (WidgetSnapshots.swift). Debug builds only.

extension RecordingAttributes.ContentState {
    /// Two minutes fourteen in, someone talking.
    static var sampleRecording: Self {
        .init(startedAt: Date.now.addingTimeInterval(-134), levels: sampleLevels)
    }

    /// Before the first wave: the first update, or an activity an older build started.
    static var sampleNoWave: Self {
        .init(startedAt: Date.now.addingTimeInterval(-3))
    }

    /// Four seconds of speech-like loudness: words with short gaps.
    static var sampleLevels: [UInt8] {
        ActivityWave.encode((0..<ActivityWave.count).map { i in
            let x = Double(i)
            let word = abs(sin(x * 0.55)) * (0.55 + 0.45 * abs(cos(x * 0.17)))
            return Float(i % 13 == 12 ? 0.02 : 0.12 + 0.8 * word)
        })
    }

    /// Stopped at 2:14.
    static var sampleSaved: Self {
        let now = Date.now
        return .init(startedAt: now.addingTimeInterval(-134), stoppedAt: now)
    }

    /// An hour and a bit in: the widest time the compact island has to hold.
    static var sampleLong: Self {
        .init(startedAt: Date.now.addingTimeInterval(-(3600 + 125)), levels: sampleLevels)
    }

    /// A call took the mic at 2:14, half a minute ago.
    static var samplePaused: Self {
        let now = Date.now
        return .init(startedAt: now.addingTimeInterval(-164), pausedAt: now.addingTimeInterval(-30))
    }

    /// Stopped by itself at 2:14: the iPhone ran out of space.
    static var sampleStopped: Self {
        let now = Date.now
        return .init(startedAt: now.addingTimeInterval(-134), stoppedAt: now, stopReason: "out of space")
    }
}

extension SharedStatus {
    /// Nothing recorded yet.
    static var sampleIdle: Self { SharedStatus() }

    /// The newest note, from this morning.
    static var sampleNote: Self {
        SharedStatus(latestTitle: "Pricing call with Sam", latestAt: Date.now.addingTimeInterval(-90 * 60))
    }

    /// Two recordings waiting to be transcribed.
    static var sampleWaiting: Self {
        SharedStatus(waiting: 2, latestTitle: "Ideas for the launch", latestAt: Date.now.addingTimeInterval(-20 * 60))
    }

    /// A title longer than any widget has room for, from yesterday.
    static var sampleLongTitle: Self {
        SharedStatus(
            waiting: 12,
            latestTitle: "Everything we decided about pricing, the launch date and who talks to the first ten customers",
            latestAt: Date.now.addingTimeInterval(-26 * 3600))
    }

    /// Recording now, with the other things still there.
    static var sampleRecording: Self {
        SharedStatus(
            recordingSince: Date.now.addingTimeInterval(-134), waiting: 1,
            latestTitle: "Ideas for the launch", latestAt: Date.now.addingTimeInterval(-20 * 60))
    }

    /// Recording, but a call took the mic at 2:14.
    static var samplePaused: Self {
        SharedStatus(
            recordingSince: Date.now.addingTimeInterval(-164), pausedAt: Date.now.addingTimeInterval(-30), waiting: 1,
            latestTitle: "Ideas for the launch", latestAt: Date.now.addingTimeInterval(-20 * 60))
    }
}
#endif
