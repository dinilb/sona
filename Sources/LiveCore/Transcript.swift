import Foundation

/// A piece of a word from a Parakeet engine. A leading space starts a new word.
public struct LiveToken: Sendable {
    public let text: String
    /// Seconds into the session's audio where the model emitted it.
    public let start: Double

    public init(text: String, start: Double) {
        self.text = text
        self.start = start
    }
}

public struct LiveWord: Sendable {
    public var text: String
    /// Emission time of the word's first and last token.
    public var start: Double
    public var last: Double
    /// Arrival-ordered speaker slot (0 = first voice heard). nil if nobody was clearly talking.
    public var speaker: Int?
    /// The diarizer has covered this word, so `speaker` won't change.
    public var resolved = false
}

public struct LiveLine: Identifiable, Sendable {
    /// Speaker slots from here up are the Mac's voices: `macSlot` alone is "Mac audio", `macSlot + 1 + n` is
    /// "Mac audio n+1" (when there are several). Ids of the Mac's lines start at `macIDs`.
    public static let macSlot = 100
    public static let macIDs = 1 << 40

    /// Absolute index of the line's first word, stable while the line exists.
    public let id: Int
    public var speaker: Int?
    /// Every word in the line has its speaker. Until then the line may still split.
    public var settled: Bool
    public var text: String
    /// Session seconds of the first word and of the last word's last token.
    public var start: Double
    public var end: Double

    public init(id: Int, speaker: Int?, settled: Bool, text: String, start: Double, end: Double) {
        self.id = id
        self.speaker = speaker
        self.settled = settled
        self.text = text
        self.start = start
        self.end = end
    }
}

/// Who's talking at each 10 ms frame, from the streaming diarizer. One byte per frame (about 3 MB for 8 hours).
public struct SpeakerTimeline: Sendable {
    public static let frameSeconds = 0.01
    /// Dominant active speaker slot per frame, -1 for nobody.
    public private(set) var frames: [Int8] = []
    /// Frames dropped off the front to keep a long day bounded.
    public private(set) var droppedFrames = 0

    public init() {}

    public var coveredSeconds: Double { Double(droppedFrames + frames.count) * Self.frameSeconds }

    public mutating func append(_ more: [Int8]) { frames.append(contentsOf: more) }

    /// Forgets frames before `seconds` (nothing earlier will be asked about again).
    public mutating func drop(before seconds: Double) {
        let n = min(Int(seconds / Self.frameSeconds) - droppedFrames, frames.count)
        guard n > 6_000 else { return }
        frames.removeFirst(n)
        droppedFrames += n
    }

    /// The speaker active for most of `from...to`, or nil if nobody was.
    public func speaker(from: Double, to: Double) -> Int? {
        let a = max(Int(from / Self.frameSeconds) - droppedFrames, 0)
        let b = min(Int(to / Self.frameSeconds) - droppedFrames, frames.count)
        guard a < b else { return nil }
        var counts = [Int](repeating: 0, count: 8)
        for i in a..<b where frames[i] >= 0 { counts[Int(frames[i])] += 1 }
        guard let best = counts.indices.max(by: { counts[$0] < counts[$1] }), counts[best] > 0 else { return nil }
        return best
    }
}

/// Who the live pass heard when, in wall-clock time, so a finished conversation can tell the offline diarizer
/// how many people it had (`count`). One entry per run of words by the same speaker, so a long day stays small.
public struct SpeakerLog: Sendable {
    public struct Run: Sendable, Equatable {
        public var slot: Int
        public var start: Date
        public var end: Date
        public var words: Int
    }

    public private(set) var runs: [Run] = []
    /// Runs older than this are forgotten (conversations are split at 75 minutes).
    public var keep: TimeInterval = 3 * 3600

    public init() {}

    /// One word by speaker `slot`, said at `time` (words come in order).
    public mutating func add(slot: Int, at time: Date) {
        if var last = runs.last, last.slot == slot, time.timeIntervalSince(last.end) < 30 {
            last.end = max(last.end, time)
            last.words += 1
            runs[runs.count - 1] = last
        } else {
            runs.append(Run(slot: slot, start: time, end: time, words: 1))
        }
        if let first = runs.first, time.timeIntervalSince(first.end) > keep {
            runs.removeAll { time.timeIntervalSince($0.end) > keep }
        }
    }

    /// How many speakers said at least `minWords` words between `from` and `to` (a stray word or two is often
    /// the diarizer guessing, not a person).
    public func count(from: Date, to: Date, minWords: Int = 3) -> Int {
        var words: [Int: Int] = [:]
        for run in runs where run.end >= from && run.start <= to { words[run.slot, default: 0] += run.words }
        return words.values.filter { $0 >= minWords }.count
    }
}

/// Words with their timing and speaker, split into lines on a pause or a change of speaker.
/// Not thread-safe: owned by whoever applies updates (the main thread in the app).
public final class LiveTranscript {
    public private(set) var words: [LiveWord] = []
    public var speakers = SpeakerTimeline()
    /// A gap this long between words starts a new line even with the same speaker.
    public var pauseSeconds = 0.7
    /// Absolute index of `words[0]` (older words are dropped on long days).
    public private(set) var dropped = 0
    private var firstUnresolved = 0
    /// The last token was a bare space (numbers come as " " then "40,000"), so the next one starts a word.
    private var spacePending = false
    /// Session time deleted ("delete the last N minutes", `forget`): words that began in it are dropped as they come.
    private var deleted: [Range<Double>] = []
    /// The word coming in began in deleted time: the rest of its pieces go too.
    private var dropping = false
    /// Lines kept from the last `lines()` (they can't change any more), the absolute index of the first word after
    /// them, and `dropped` when they were kept.
    private var stableLines: [LiveLine] = []
    private var stableEnd = 0
    private var stableDropped = 0
    /// The words hidden when they were kept.
    private var stableHidden: Set<Int> = []

    public init() {}

    public func add(_ tokens: [LiveToken]) {
        for token in tokens {
            let text = token.text.trimmingCharacters(in: .whitespaces)
            if text.isEmpty {
                spacePending = true
                continue
            }
            if token.text.hasPrefix(" ") || spacePending || words.isEmpty && !dropping {
                spacePending = false
                dropping = deleted.contains { $0.contains(token.start) }
                if !dropping { words.append(LiveWord(text: text, start: token.start, last: token.start)) }
            } else if !dropping {
                words[words.count - 1].text += token.text
                words[words.count - 1].last = token.start
            }
        }
        // Keep a long day bounded (the window and the feed only show the recent part anyway).
        if words.count > 8_000 {
            let n = 2_000
            words.removeFirst(n)
            dropped += n
            firstUnresolved = max(firstUnresolved - n, 0)
            if let first = words.first { speakers.drop(before: first.start - 1) }
        }
    }

    /// Forgets `words[index...]` ("delete the last N minutes"). What comes next starts a new word.
    public func removeWords(from index: Int) {
        guard index < words.count else { return }
        words.removeSubrange(max(index, 0)...)
        firstUnresolved = min(firstUnresolved, words.count)
        spacePending = true
        resetStableLines()
    }

    /// "Delete the last N minutes": forgets `words[index...]`, and, for the rest of this transcript, words that began
    /// `during` (session seconds from the cut to the click): ones still being decoded at the click arrive after it.
    public func forget(from index: Int, during: Range<Double>) {
        removeWords(from: index)
        if !during.isEmpty { deleted.append(during) }
    }

    /// Gives a speaker to every word the diarizer has covered (plus a little margin, since a token is
    /// emitted near the start of its sound). Returns the absolute indices that just got one.
    @discardableResult
    public func resolveSpeakers() -> Range<Int> {
        let begin = firstUnresolved
        let covered = speakers.coveredSeconds
        while firstUnresolved < words.count {
            let w = words[firstUnresolved]
            let to = w.last + 0.24
            guard covered >= to else { break }
            let previous = firstUnresolved > 0 ? words[firstUnresolved - 1].speaker : nil
            words[firstUnresolved].speaker = speakers.speaker(from: w.start - 0.04, to: to) ?? previous
            words[firstUnresolved].resolved = true
            firstUnresolved += 1
        }
        return (begin + dropped)..<(firstUnresolved + dropped)
    }

    /// The lines, redoing only the end: lines whose words all have their speakers, followed by a word that has its
    /// speaker too, can't change any more (where they end is settled), so they're kept from last time. Called on
    /// every update, it was rebuilding hours of words several times a second.
    /// `hiding`: absolute indices of words not to show (the mic's echoes of the Mac's audio). A change to which words
    /// are hidden among the kept lines starts the kept lines over.
    public func lines(hiding hidden: Set<Int> = []) -> [LiveLine] {
        if stableDropped != dropped || stableEnd - dropped > words.count
            || hidden != stableHidden && hidden.symmetricDifference(stableHidden).contains(where: { $0 < stableEnd })
        {
            resetStableLines()
        }
        stableHidden = hidden
        var tail = lines(from: stableEnd - dropped, hiding: hidden)
        // Lines before the last one that starts with a word that has its speaker are settled for good.
        let resolved = firstUnresolved + dropped
        if let last = tail.lastIndex(where: { $0.id < resolved }), last > 0 {
            stableLines += tail[..<last]
            stableEnd = tail[last].id
            tail.removeFirst(last)
        }
        return stableLines + tail
    }

    private func resetStableLines() {
        stableLines = []
        stableEnd = dropped
        stableDropped = dropped
    }

    /// Lines from `words[start...]`, leaving out `hidden`; the first shown word from `start` begins a line.
    func lines(from start: Int, hiding hidden: Set<Int> = []) -> [LiveLine] {
        var lines: [LiveLine] = []
        var previous: LiveWord?
        for i in start..<words.count where hidden.isEmpty || !hidden.contains(i + dropped) {
            let w = words[i]
            let pause = previous.map { w.start - $0.last > pauseSeconds } ?? true
            let current = lines.last
            let newSpeaker = w.speaker != nil && current?.speaker != nil && w.speaker != current?.speaker
            if pause || newSpeaker || current == nil {
                lines.append(LiveLine(id: i + dropped, speaker: w.speaker, settled: w.resolved, text: w.text, start: w.start, end: w.last))
            } else {
                lines[lines.count - 1].text += " " + w.text
                lines[lines.count - 1].end = w.last
                if lines[lines.count - 1].speaker == nil { lines[lines.count - 1].speaker = w.speaker }
                lines[lines.count - 1].settled = lines[lines.count - 1].settled && w.resolved
            }
            previous = w
        }
        return lines
    }
}
