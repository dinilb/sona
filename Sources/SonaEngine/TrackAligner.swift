import Foundation

/// Lines this Mac's audio up with the mic's by capture time, for the Listener: each mic frame goes on with the Mac's
/// samples for the same moment (silence where none came), or with none at all while the Mac plays nothing.
///
/// The two arrive separately and not quite together, so while the Mac's audio is flowing a mic frame waits until
/// the Mac's has covered it, at most `hold`. With no Mac audio a frame goes straight on. Pure (time is passed in),
/// so it's tested without audio; the recorder's pump owns one.
public struct TrackAligner {
    public struct Frame: Equatable {
        public var mic: [Float]
        public var mac: [Float]?
        public var at: Date
    }

    /// Longest a mic frame waits for the Mac's audio.
    public static let hold = 0.5
    /// The Mac's audio stopped if none has come for this long.
    public static let idle = 2.0
    /// Two pieces this close to following on are taken as following on (capture times jitter by a few samples).
    static let slack = 0.05
    /// Most of the Mac's audio kept ahead of the mic (the mic stalled): older goes.
    static let most = 30 * rate
    static let rate = 16_000

    /// The Mac's samples not yet handed out; `mac[0]` was captured at `macStart`.
    private var mac: [Float] = []
    private var macStart: Date?
    private var lastMac: Date?
    private var pending: [(samples: [Float], at: Date)] = []
    /// Where the next mic frame should start in the Mac's audio (so jitter never repeats or skips a sample).
    private var nextIndex: Int?

    public init() {}

    /// The Mac is playing right now (its audio came in the last `idle` seconds).
    public func macFlowing(now: Date) -> Bool { lastMac.map { now.timeIntervalSince($0) < Self.idle } ?? false }

    public mutating func addMac(_ samples: [Float], at time: Date, now: Date) {
        guard !samples.isEmpty else { return }
        lastMac = now
        guard let start = macStart else {
            macStart = time
            mac = samples
            nextIndex = nil
            return
        }
        var index = Int((time.timeIntervalSince(start) * Double(Self.rate)).rounded())
        if abs(index - mac.count) <= Int(Self.slack * Double(Self.rate)) { index = mac.count }
        if index > mac.count + 60 * Self.rate || index < 0 && -index > Self.most {
            // Far off (a long gap, a clock jump): start over from here.
            macStart = time
            mac = samples
            nextIndex = nil
            return
        }
        if index > mac.count { mac += [Float](repeating: 0, count: index - mac.count) }
        if index < 0 {
            // Before what's kept: only the part after it.
            guard samples.count + index > 0 else { return }
            mac.replaceSubrange(0..<min(mac.count, samples.count + index), with: samples[(-index)...])
        } else if index < mac.count {
            // Overlaps what's there (already counted): only what's new.
            let overlap = min(mac.count - index, samples.count)
            mac += samples[overlap...]
        } else {
            mac += samples
        }
        if mac.count > Self.most {
            let drop = mac.count - Self.most
            mac.removeFirst(drop)
            macStart = start.addingTimeInterval(Double(drop) / Double(Self.rate))
            nextIndex = nextIndex.map { $0 - drop }
        }
    }

    public mutating func addMic(_ samples: [Float], at time: Date) {
        pending.append((samples, time))
    }

    /// The mic frames ready to go on at `now`, with the Mac's audio for each.
    public mutating func ready(now: Date) -> [Frame] {
        let flowing = macFlowing(now: now)
        var out: [Frame] = []
        while let first = pending.first {
            let end = first.at.addingTimeInterval(Double(first.samples.count) / Double(Self.rate))
            guard !flowing || macCovered(first) || now.timeIntervalSince(end) >= Self.hold else { break }
            pending.removeFirst()
            out.append(Frame(mic: first.samples, mac: take(for: first, flowing: flowing), at: first.at))
        }
        // Stopped, and all of it handed out: forget it.
        if !flowing, mac.isEmpty, macStart != nil { reset() }
        return out
    }

    /// Everything waiting, with whatever Mac audio there is (a close, a pause: nothing more is coming in time).
    public mutating func flush(now: Date) -> [Frame] {
        let flowing = macFlowing(now: now)
        let out = pending.map { Frame(mic: $0.samples, mac: take(for: $0, flowing: flowing), at: $0.at) }
        pending = []
        return out
    }

    /// Forget everything (after a pause or sleep).
    public mutating func reset() {
        mac = []
        macStart = nil
        nextIndex = nil
        lastMac = nil
    }

    private func macCovered(_ frame: (samples: [Float], at: Date)) -> Bool {
        guard let start = macStart else { return false }
        let end = frame.at.addingTimeInterval(Double(frame.samples.count) / Double(Self.rate))
        return start.addingTimeInterval(Double(mac.count) / Double(Self.rate)) >= end.addingTimeInterval(-Self.slack)
    }

    /// The Mac's samples for a mic frame (silence where none came, while it's flowing), dropping what's now behind.
    /// Nil if the Mac's audio hadn't begun by then, or has stopped and none of it is left for this frame.
    private mutating func take(for frame: (samples: [Float], at: Date), flowing: Bool) -> [Float]? {
        guard let start = macStart else { return nil }
        let n = frame.samples.count
        var index = Int((frame.at.timeIntervalSince(start) * Double(Self.rate)).rounded())
        if let next = nextIndex, abs(index - next) <= Int(Self.slack * Double(Self.rate)) { index = next }
        guard index + n > 0 else { return nil }  // before the Mac's audio began
        var out: [Float]?
        if index < mac.count {
            var piece = [Float](repeating: 0, count: n)
            for k in max(index, 0)..<min(index + n, mac.count) { piece[k - index] = mac[k] }
            out = piece
        } else if flowing {
            out = [Float](repeating: 0, count: n)
        }
        // Drop what this frame used and everything before it.
        let used = min(index + n, mac.count)
        if used > 0 {
            mac.removeFirst(used)
            macStart = start.addingTimeInterval(Double(used) / Double(Self.rate))
        }
        nextIndex = index + n - max(used, 0)
        return out
    }
}
