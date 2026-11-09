import Foundation

/// When this Mac plays through its own speakers, the mic hears it too, so the same words come in twice: once on
/// the Mac track (clean, from the tap) and once on the mic track (the room). This finds the mic's copies so they
/// can be flagged (`Word.echo`) and kept out of the note's lines, while real room speech over the top stays.
///
/// Two rules, after hearsay's echo filter (MIT, see THIRD_PARTY.md):
/// - **Runs of twins.** A mic word with a twin on the Mac track (the same word, give or take a letter) within
///   `twinSeconds`, in a run of at least `runLength` such words at a steady lag a little behind the Mac's, is
///   an echo. One mis-heard word inside a run goes with it. Someone repeating what a video said does it a second
///   or more later, so their run's lag is too long, and a common word or two in common is never enough.
/// - **A distinctive word.** A word of 6+ letters, exactly the Mac's within half a second, is an echo on its own.
/// - **The loudness gate** (`EchoGate`): where the mic's loudness rose and fell with the Mac's for 1.5 s (and the
///   next or previous 1.5 s agrees), the mic was mostly the Mac's sound; there a single twin is enough.
///
/// Pure, so it's tested without audio. Times are seconds on one clock for both tracks.
public enum EchoFilter {
    public struct Timed: Sendable, Equatable {
        public var text: String
        public var start: Double

        public init(_ text: String, _ start: Double) {
            self.text = text
            self.start = start
        }
    }

    /// A twin is at most this far from the mic word (speaker-to-mic delay plus the two transcriptions' timing).
    public static let twinSeconds = 2.0
    /// Twins in a row needed to call a run an echo, outside the loudness gate's windows.
    public static let runLength = 3
    /// An echo's run comes this much after the Mac's words (mic minus Mac), as a median. Both tracks are stamped
    /// on the same clock, so it's close to zero; word timings jitter by up to about half a second either way.
    public static let runLag: ClosedRange<Double> = -0.75...1.0
    /// Each twin's lag within this of the run's.
    public static let lagSpread = 0.75
    /// A twin this long or longer can carry a run on past a mis-heard word.
    static let strongLetters = 4
    /// A word this long, the same as the Mac's within `closeSeconds`, is an echo on its own.
    static let distinctLetters = 6
    static let closeSeconds = 0.5

    /// For each mic word, whether it's an echo of the Mac's. `confirmed`: times the loudness gate says the mic was
    /// the Mac's sound. Both lists in time order.
    public static func echoes(mic: [Timed], mac: [Timed], confirmed: [Range<Double>] = []) -> [Bool] {
        var out = [Bool](repeating: false, count: mic.count)
        guard !mic.isEmpty, !mac.isEmpty else { return out }
        let macKeys = mac.map { normalized($0.text) }
        let keys = mic.map { normalized($0.text) }
        // Every mic word's twins, as lags (mic minus Mac), and whether one is the very same word close by.
        var twins: [[Double]] = []
        var close = [Bool](repeating: false, count: mic.count)
        twins.reserveCapacity(mic.count)
        var lo = 0
        for (i, w) in mic.enumerated() {
            while lo < mac.count, mac[lo].start < w.start - twinSeconds { lo += 1 }
            let key = keys[i]
            var lags: [Double] = []
            var j = lo
            while j < mac.count, mac[j].start <= w.start + twinSeconds {
                if !key.isEmpty, similar(key, macKeys[j]) {
                    let lag = w.start - mac[j].start
                    lags.append(lag)
                    if key == macKeys[j], abs(lag) <= closeSeconds { close[i] = true }
                }
                j += 1
            }
            twins.append(lags)
        }

        // Runs: twins at a steady lag, one stray word allowed between two of them.
        var run: [Int] = []  // mic indices in the run, strays included
        var runLags: [Double] = []
        var stray: Int?
        func endRun() {
            if runLags.count >= runLength, runLag.contains(median(runLags)) { for i in run { out[i] = true } }
            run = []
            runLags = []
            stray = nil
        }
        for i in mic.indices {
            let reference = runLags.last ?? 0
            let lag = twins[i].min { abs($0 - reference) < abs($1 - reference) }
            let steady = lag.map { runLags.isEmpty ? runLag.contains($0) : abs($0 - reference) <= lagSpread } ?? false
            let near = run.last.map { mic[i].start - mic[$0].start <= twinSeconds } ?? true
            // A short word ("the", "and") is too common to carry a run across a stray word.
            let bridges = stray == nil || keys[i].count >= strongLetters
            if let lag, steady, near, bridges {
                if let s = stray { run.append(s) }
                stray = nil
                run.append(i)
                runLags.append(lag)
            } else if !run.isEmpty, stray == nil, near {
                stray = i
            } else {
                endRun()
                if let fresh = twins[i].min(by: { abs($0) < abs($1) }), runLag.contains(fresh) {
                    run = [i]
                    runLags = [fresh]
                }
            }
        }
        endRun()

        // A long word, the very same as the Mac's within half a second: an echo even on its own ("Brisbane" just
        // after the room spoke over the rest of the video's sentence).
        for i in mic.indices where !out[i] && close[i] && keys[i].count >= distinctLetters { out[i] = true }

        // The loudness gate's windows: any twin will do, and a stray word between two echoes there goes too.
        guard !confirmed.isEmpty else { return out }
        func inGate(_ t: Double) -> Bool { confirmed.contains { $0.contains(t) } }
        for i in mic.indices where !out[i] && inGate(mic[i].start) && twins[i].contains(where: { abs($0) <= twinSeconds }) {
            out[i] = true
        }
        for i in mic.indices.dropFirst().dropLast() where !out[i] && out[i - 1] && out[i + 1] && inGate(mic[i].start) {
            out[i] = true
        }
        return out
    }

    /// Lowercase letters and digits only ("Station," → "station", "40,000" → "40000").
    static func normalized(_ s: String) -> String {
        String(s.lowercased().unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) }.map(Character.init))
    }

    /// The same word as transcribed twice: equal, or a letter off for 4+ letters (two for 8+).
    static func similar(_ a: String, _ b: String) -> Bool {
        if a == b { return true }
        let n = min(a.count, b.count)
        guard n >= 4, abs(a.count - b.count) <= 2 else { return false }
        return distance(Array(a), Array(b), limit: n >= 8 ? 2 : 1) <= (n >= 8 ? 2 : 1)
    }

    /// Edit distance, giving up once it's past `limit`. Both non-empty.
    static func distance(_ a: [Character], _ b: [Character], limit: Int) -> Int {
        var previous = Array(0...b.count)
        for i in 1...a.count {
            var row = [Int](repeating: i, count: b.count + 1)
            for j in 1...b.count {
                row[j] = min(previous[j] + 1, row[j - 1] + 1, previous[j - 1] + (a[i - 1] == b[j - 1] ? 0 : 1))
            }
            if row.min()! > limit { return limit + 1 }
            previous = row
        }
        return previous[b.count]
    }

    static func median(_ xs: [Double]) -> Double {
        let s = xs.sorted()
        return s.isEmpty ? 0 : s.count % 2 == 1 ? s[s.count / 2] : (s[s.count / 2 - 1] + s[s.count / 2]) / 2
    }
}

/// 10 ms loudness in dBFS, the curves `EchoGate` compares.
public enum Loudness {
    public static let frameSeconds = 0.01
    /// A frame louder than this counts as sound.
    public static let loud: Float = -46
    /// Digital silence, and audio that isn't there.
    public static let floor: Float = -120

    /// RMS dBFS per 10 ms of 16 kHz mono audio.
    public static func curve(_ samples: [Float], rate: Int = 16_000) -> [Float] {
        let n = rate / 100
        var out: [Float] = []
        out.reserveCapacity(samples.count / n + 1)
        var i = 0
        while i < samples.count {
            let end = min(i + n, samples.count)
            var sum: Float = 0
            for k in i..<end { sum += samples[k] * samples[k] }
            out.append(db(sum / Float(end - i)))
            i = end
        }
        return out
    }

    /// dBFS of a mean square.
    public static func db(_ meanSquare: Float) -> Float { meanSquare > 0 ? max(floor, 10 * log10(meanSquare)) : floor }
}

/// Finds where the mic was mostly the Mac's own sound: its loudness curve rose and fell with the Mac track's,
/// slightly later (the speakers to the mic). The approach and its numbers are hearsay's (MIT): 1.5 s windows, a
/// Pearson correlation of the two dB curves of at least 0.75 at some lag, both with 0.3 s of sound, and a
/// neighbouring window agreeing on the lag within 50 ms (unrelated speech reaches 0.75 in 5 to 15% of windows,
/// at scattered lags).
public enum EchoGate {
    public static let windowSeconds = 1.5
    static let windowFrames = 150
    /// Lags searched, in 10 ms frames: the mic up to 0.1 s ahead (timing jitter) to 0.5 s behind.
    static let lags = -10...50
    static let matchLevel: Float = 0.75
    static let minLoudFrames = 30
    static let neighbourFrames = 5
    /// Silence below this doesn't count in the correlation (so digital silence can't dominate it).
    static let correlationFloor: Float = -70

    /// The confirmed windows, in seconds (each runs on by its lag, where the copy still is).
    public static func confirmed(mic: [Float], mac: [Float]) -> [Range<Double>] {
        let windows = min(mic.count, mac.count) / windowFrames
        guard windows > 0 else { return [] }
        let best = (0..<windows).map { match(mic: mic, mac: mac, window: $0) }
        var out: [Range<Double>] = []
        for (w, m) in best.enumerated() {
            guard let m else { continue }
            let agrees = [w - 1, w + 1].contains { n in
                n >= 0 && n < best.count && best[n].map { abs($0 - m) <= neighbourFrames } == true
            }
            guard agrees else { continue }
            let from = Double(w) * windowSeconds
            out.append(from..<(from + windowSeconds + Double(max(m, 0)) * Loudness.frameSeconds))
        }
        return out
    }

    /// The lag (frames, mic behind the Mac) where window `w` of the two curves correlates best, if it reaches the
    /// match level.
    static func match(mic: [Float], mac: [Float], window w: Int) -> Int? {
        let start = w * windowFrames
        guard start + windowFrames <= mac.count, loudFrames(mac, start) >= minLoudFrames else { return nil }
        var best: (lag: Int, r: Float)?
        for lag in lags {
            let at = start + lag
            guard at >= 0, at + windowFrames <= mic.count, loudFrames(mic, at) >= minLoudFrames,
                let r = correlation(mac, start, mic, at), r >= matchLevel
            else { continue }
            if best == nil || r > best!.r { best = (lag, r) }
        }
        return best?.lag
    }

    static func loudFrames(_ x: [Float], _ at: Int) -> Int {
        var n = 0
        for k in at..<(at + windowFrames) where x[k] > Loudness.loud { n += 1 }
        return n
    }

    static func correlation(_ a: [Float], _ ai: Int, _ b: [Float], _ bi: Int) -> Float? {
        let n = windowFrames
        var sa: Float = 0, sb: Float = 0
        for k in 0..<n {
            sa += max(a[ai + k], correlationFloor)
            sb += max(b[bi + k], correlationFloor)
        }
        let ma = sa / Float(n), mb = sb / Float(n)
        var cov: Float = 0, va: Float = 0, vb: Float = 0
        for k in 0..<n {
            let x = max(a[ai + k], correlationFloor) - ma, y = max(b[bi + k], correlationFloor) - mb
            cov += x * y
            va += x * x
            vb += y * y
        }
        guard va > 0, vb > 0 else { return nil }
        return cov / (va * vb).squareRoot()
    }
}
