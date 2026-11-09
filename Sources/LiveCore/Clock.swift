import AVFoundation
import Foundation

/// Seconds on the mach host clock, the clock Core Audio stamps mic buffers with.
public func hostNow() -> Double { AVAudioTime.seconds(forHostTime: mach_absolute_time()) }

/// Maps a session's 16 kHz sample index to the host time that sample reached the mic, so a word's audio
/// time can be compared with when it reached the screen. Audio sources mark an anchor per buffer.
// @unchecked: `anchors` is only touched under `lock`.
public final class AudioClock: @unchecked Sendable {
    public static let sampleRate = 16_000.0
    private var anchors: [(index: Int, time: Double)] = []
    private let lock = NSLock()

    public init() {}

    public func mark(index: Int, hostTime: Double) {
        lock.lock()
        defer { lock.unlock() }
        anchors.append((index, hostTime))
        if anchors.count > 20_000 { anchors.removeFirst(10_000) }
    }

    /// Host time of the audio `seconds` into the session.
    public func hostTime(atSeconds seconds: Double) -> Double? {
        let index = Int(seconds * Self.sampleRate)
        lock.lock()
        defer { lock.unlock() }
        guard !anchors.isEmpty else { return nil }
        // Last anchor at or before `index` (anchors arrive in order).
        var lo = 0, hi = anchors.count - 1, found = 0
        while lo <= hi {
            let mid = (lo + hi) / 2
            if anchors[mid].index <= index { found = mid; lo = mid + 1 } else { hi = mid - 1 }
        }
        let anchor = anchors[found]
        return anchor.time + Double(index - anchor.index) / Self.sampleRate
    }

    /// Session seconds of the audio captured at `hostTime` (for "what was said since the key went down"), never past
    /// the next anchor (audio after a gap, a closed mic say, starts there).
    public func seconds(atHost hostTime: Double) -> Double? {
        lock.lock()
        defer { lock.unlock() }
        guard !anchors.isEmpty else { return nil }
        var lo = 0, hi = anchors.count - 1, found = 0
        while lo <= hi {
            let mid = (lo + hi) / 2
            if anchors[mid].time <= hostTime { found = mid; lo = mid + 1 } else { hi = mid - 1 }
        }
        let anchor = anchors[found]
        let seconds = Double(anchor.index) / Self.sampleRate + (hostTime - anchor.time)
        return found + 1 < anchors.count ? min(seconds, Double(anchors[found + 1].index) / Self.sampleRate) : seconds
    }

    /// Milliseconds from the audio at `seconds` being captured to now.
    public func lagMs(atSeconds seconds: Double, now: Double = hostNow()) -> Double? {
        hostTime(atSeconds: seconds).map { (now - $0) * 1000 }
    }
}

/// Session seconds to wall-clock time, noted as words arrive (moments after they were said), so a long session's
/// lines keep their real times across sleep (the host clock stops then), pauses and a closed mic. Between marks,
/// time runs with the audio.
public struct WallClock: Sendable {
    private var marks: [(seconds: Double, date: Date)] = []
    /// Marks kept; at one a second of speech, hours of talk.
    public var keep = 8_000

    public init() {}

    /// The audio at session `seconds` was captured at `date`. Marks closer than a second apart are skipped.
    public mutating func mark(_ seconds: Double, at date: Date) {
        if let last = marks.last, seconds < last.seconds + 1 { return }
        marks.append((seconds, date))
        if marks.count > keep { marks.removeFirst(keep / 2) }
    }

    /// Wall-clock time of the audio at session `seconds`, from the last mark at or before it.
    public func date(atSeconds seconds: Double) -> Date? {
        guard !marks.isEmpty else { return nil }
        var lo = 0, hi = marks.count - 1, found = 0
        while lo <= hi {
            let mid = (lo + hi) / 2
            if marks[mid].seconds <= seconds { found = mid; lo = mid + 1 } else { hi = mid - 1 }
        }
        return marks[found].date.addingTimeInterval(seconds - marks[found].seconds)
    }

    /// Session seconds of the audio captured at `date` (the other way round): from the last mark at or before it,
    /// never past the next mark (audio after a gap starts there). Nil before any mark.
    public func seconds(at date: Date) -> Double? {
        guard let first = marks.first else { return nil }
        guard first.date <= date else { return max(0, first.seconds - first.date.timeIntervalSince(date)) }
        var lo = 0, hi = marks.count - 1, found = 0
        while lo <= hi {
            let mid = (lo + hi) / 2
            if marks[mid].date <= date { found = mid; lo = mid + 1 } else { hi = mid - 1 }
        }
        let seconds = marks[found].seconds + date.timeIntervalSince(marks[found].date)
        return found + 1 < marks.count ? min(seconds, marks[found + 1].seconds) : seconds
    }
}

/// Latency samples in milliseconds.
public struct LatencyStats: Sendable {
    public private(set) var all: [Double] = []
    /// Samples ever added (`all` keeps only the latest when `keepLast` is set).
    public private(set) var count = 0
    private let keepLast: Int?

    /// `keepLast`: bound the memory of a session that runs all day (the app only shows recent percentiles).
    public init(keepLast: Int? = nil) { self.keepLast = keepLast }

    public mutating func add(_ ms: Double) {
        all.append(ms)
        count += 1
        if let keepLast, all.count > 2 * keepLast { all.removeFirst(all.count - keepLast) }
    }
    public var last: Double? { all.last }

    /// Percentile (0...100) over the last `window` samples, or all of them.
    public func percentile(_ p: Double, window: Int? = nil) -> Double? {
        let xs = window.map { Array(all.suffix($0)) } ?? all
        guard !xs.isEmpty else { return nil }
        let sorted = xs.sorted()
        let rank = Int((p / 100 * Double(sorted.count - 1)).rounded())
        return sorted[Swift.min(Swift.max(rank, 0), sorted.count - 1)]
    }

    public var mean: Double? { all.isEmpty ? nil : all.reduce(0, +) / Double(all.count) }
    public var max: Double? { all.max() }
}
