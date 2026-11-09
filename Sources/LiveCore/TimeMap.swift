import Foundation

/// With the voice gate on, the engines only hear the speech, so their clock ("fed" samples) runs behind the
/// session's. This maps a fed sample back to the session sample it came from: one segment per stretch of
/// audio that was fed without a break.
public struct TimeMap: Sendable {
    /// A stretch fed without a break: fed samples from `fed` on are session samples from `session` on.
    struct Segment: Sendable, Equatable {
        let fed: Int
        let session: Int
    }

    private(set) var segments: [Segment] = []
    /// Samples fed so far.
    public private(set) var fedCount = 0
    /// Session index just after the last fed sample.
    public private(set) var sessionEnd = 0

    public init() {}

    /// Records that `count` samples starting at session sample `sessionStart` were just fed.
    public mutating func append(sessionStart: Int, count: Int) {
        guard count > 0 else { return }
        if segments.isEmpty || sessionStart != sessionEnd {
            segments.append(Segment(fed: fedCount, session: sessionStart))
        }
        fedCount += count
        sessionEnd = sessionStart + count
    }

    /// The session sample that fed sample `fed` came from. Past the end (an engine's flush), it carries on
    /// from the last segment; before the start, from the first.
    public func sessionSample(fed: Int) -> Int {
        guard !segments.isEmpty else { return fed }
        var lo = 0, hi = segments.count - 1, found = 0
        while lo <= hi {
            let mid = (lo + hi) / 2
            if segments[mid].fed <= fed { found = mid; lo = mid + 1 } else { hi = mid - 1 }
        }
        let s = segments[found]
        return s.session + (fed - s.fed)
    }

    public func sessionSeconds(fedSeconds: Double) -> Double {
        let fed = fedSeconds * AudioClock.sampleRate
        let whole = fed.rounded(.down)
        // Keep the sub-sample part so identity maps stay exact.
        return (Double(sessionSample(fed: Int(whole))) + (fed - whole)) / AudioClock.sampleRate
    }
}

/// Places the diarizer's 10 ms frames (contiguous in fed time) at their session positions, filling the
/// skipped silence with -1, so `SpeakerTimeline` stays one frame per 10 ms of session audio.
public struct SpeakerFrameMapper: Sendable {
    public static let samplesPerFrame = 160
    /// Fed frames seen so far.
    private var fedFrames = 0
    /// Next session frame to emit.
    public private(set) var nextSessionFrame = 0

    public init() {}

    public mutating func map(_ frames: [Int8], with timeMap: TimeMap) -> [Int8] {
        var out: [Int8] = []
        out.reserveCapacity(frames.count)
        for f in frames {
            let s = timeMap.sessionSample(fed: fedFrames * Self.samplesPerFrame) / Self.samplesPerFrame
            fedFrames += 1
            // The session offset only grows, so `s` never goes backwards; guard anyway.
            guard s >= nextSessionFrame else { continue }
            if s > nextSessionFrame { out.append(contentsOf: repeatElement(-1, count: s - nextSessionFrame)) }
            out.append(f)
            nextSessionFrame = s + 1
        }
        return out
    }
}
