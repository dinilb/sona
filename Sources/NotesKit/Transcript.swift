import Foundation

/// One word with its time span (seconds from the conversation start) and its speaker.
public struct Word: Codable, Equatable, Sendable {
    public var word: String
    public var start: Double
    public var end: Double
    public var speaker: String
    /// Where it was heard: nil for the mic, `Tracks.mac` for what this Mac played. Absent from older notes.
    public var track: String?
    /// A mic word that was only the Mac's own sound coming back through the speakers (`EchoFilter`): kept in the
    /// .json, never shown in the note's lines. Absent otherwise.
    public var echo: Bool?

    public init(word: String, start: Double, end: Double, speaker: String, track: String? = nil, echo: Bool? = nil) {
        self.word = word
        self.start = start
        self.end = end
        self.speaker = speaker
        self.track = track
        self.echo = echo
    }

    /// Shown in the note (not an echo of the Mac's audio).
    public var shown: Bool { echo != true }
}

/// A diarizer turn, with the speaker already renamed to "Speaker N".
public struct Turn: Codable, Equatable, Sendable {
    public var speaker: String
    public var start: Double
    public var end: Double

    public init(speaker: String, start: Double, end: Double) {
        self.speaker = speaker
        self.start = start
        self.end = end
    }
}

/// A prior on how many people are talking in one conversation, for the offline diarizer.
/// `min == max` asks for exactly that many. Either bound can be left open.
///
/// The offline diarizer only uses it when its own count falls outside the range: then it re-clusters to
/// the nearest bound. A count it already got right is left alone.
public struct SpeakerHint: Codable, Equatable, Sendable, CustomStringConvertible {
    public var min: Int?
    public var max: Int?

    public init(min: Int? = nil, max: Int? = nil) {
        let lo = min.map { Swift.max(1, $0) }
        let hi = max.map { Swift.max(1, $0) }
        if let lo, let hi, lo > hi {
            self.min = hi
            self.max = lo
        } else {
            self.min = lo
            self.max = hi
        }
    }

    public static func exactly(_ n: Int) -> SpeakerHint { SpeakerHint(min: n, max: n) }

    /// Exact count when both bounds agree.
    public var exact: Int? { min != nil && min == max ? min : nil }

    public var isEmpty: Bool { min == nil && max == nil }

    /// Largest count accepted: more is almost certainly a typo, and it would silently over-split.
    public static let most = 10

    /// Parses `3` (exactly 3), `2-4` / `2...4` (a range), `2-` (at least 2) or `-4` (at most 4), 1 to `most`.
    public init?(parsing raw: String) {
        let s = raw.replacingOccurrences(of: "...", with: "-").trimmingCharacters(in: .whitespaces)
        if !s.hasPrefix("-"), let n = Int(s) {
            guard (1...Self.most).contains(n) else { return nil }
            self = .exactly(n)
            return
        }
        let parts = s.split(separator: "-", maxSplits: 1, omittingEmptySubsequences: false).map(String.init)
        guard parts.count == 2 else { return nil }
        let lo = parts[0].isEmpty ? nil : Int(parts[0])
        let hi = parts[1].isEmpty ? nil : Int(parts[1])
        if (!parts[0].isEmpty && lo == nil) || (!parts[1].isEmpty && hi == nil) { return nil }
        if lo == nil && hi == nil { return nil }
        if let lo, !(1...Self.most).contains(lo) { return nil }
        if let hi, !(1...Self.most).contains(hi) { return nil }
        if let lo, let hi, lo > hi { return nil }
        self.init(min: lo, max: hi)
    }

    public var description: String {
        if let exact { return "\(exact)" }
        return "\(min.map(String.init) ?? "")-\(max.map(String.init) ?? "")"
    }
}

/// Everything the note writer needs for one conversation.
public struct Transcript: Sendable {
    public var startedAt: Date
    public var duration: Double
    public var text: String
    public var words: [Word]
    public var turns: [Turn]
    public var asrSeconds: Double
    public var diarizationSeconds: Double
    public var model: String

    public init(
        startedAt: Date, duration: Double, text: String, words: [Word], turns: [Turn], asrSeconds: Double,
        diarizationSeconds: Double, model: String
    ) {
        self.startedAt = startedAt
        self.duration = duration
        self.text = text
        self.words = words
        self.turns = turns
        self.asrSeconds = asrSeconds
        self.diarizationSeconds = diarizationSeconds
        self.model = model
    }

    /// Speakers in order of first appearance (echo words don't count: they aren't shown).
    public var speakers: [String] {
        var seen: [String] = []
        for w in words where w.shown && !seen.contains(w.speaker) { seen.append(w.speaker) }
        return seen
    }

    /// Only what was said before `seconds` from the start ("delete the last N minutes"): a word is gone if it
    /// started then or later.
    public func cut(at seconds: Double) -> Transcript {
        var t = self
        t.words = words.filter { $0.start < seconds }
        t.turns = turns.filter { $0.start < seconds }.map { Turn(speaker: $0.speaker, start: $0.start, end: min($0.end, seconds)) }
        t.text = t.words.filter(\.shown).map(\.word).joined(separator: " ")
        t.duration = min(duration, max(seconds, t.words.last?.end ?? 0))
        return t
    }
}

/// A rendered transcript line: one speaker talking, from `start` until the next line.
public struct Line: Equatable, Sendable {
    public var speaker: String
    public var start: Double
    public var end: Double
    public var text: String

    public init(speaker: String, start: Double, end: Double, text: String) {
        self.speaker = speaker
        self.start = start
        self.end = end
        self.text = text
    }
}

public enum Lines {
    public static let pauseSplit = 3.0
    public static let maxSeconds = 30.0

    /// Group consecutive words into lines. A new line starts when the speaker changes, when the same speaker
    /// pauses for `pauseSplit` seconds, or at the first sentence end once a line runs past `maxSeconds`
    /// (so a long monologue doesn't become one wall of text). Echo words (`Word.echo`) aren't shown.
    public static func from(_ words: [Word], pauseSplit: Double = pauseSplit, maxSeconds: Double = maxSeconds) -> [Line] {
        var lines: [Line] = []
        var current: [Word] = []

        func flush() {
            guard let first = current.first, let last = current.last else { return }
            let text = current.map(\.word).joined(separator: " ")
            lines.append(Line(speaker: first.speaker, start: first.start, end: last.end, text: text))
            current = []
        }

        for word in words where word.shown {
            if let last = current.last, let first = current.first, splits(first, last, word, pauseSplit, maxSeconds) { flush() }
            current.append(word)
        }
        flush()
        return lines
    }

    /// `next` starts a new line after one running from `first` to `last`.
    static func splits(_ first: Word, _ last: Word, _ next: Word, _ pauseSplit: Double = pauseSplit, _ maxSeconds: Double = maxSeconds) -> Bool {
        let speakerChanged = last.speaker != next.speaker
        let paused = next.start - last.end >= pauseSplit
        let long = last.end - first.start >= maxSeconds && endsSentence(last.word)
        return speakerChanged || paused || long
    }

    static func endsSentence(_ word: String) -> Bool {
        guard let c = word.last else { return false }
        return c == "." || c == "?" || c == "!"
    }

    /// `[mm:ss]`, or `[h:mm:ss]` past an hour.
    public static func clock(_ seconds: Double) -> String {
        let s = max(0, Int(seconds.rounded(.down)))
        if s >= 3600 { return String(format: "%d:%02d:%02d", s / 3600, (s % 3600) / 60, s % 60) }
        return String(format: "%02d:%02d", s / 60, s % 60)
    }

    /// "1m 9s", "1h 12m", "40s".
    public static func durationText(_ seconds: Double) -> String {
        let s = max(0, Int(seconds.rounded()))
        if s >= 3600 { return "\(s / 3600)h \((s % 3600) / 60)m" }
        if s >= 60 { return "\(s / 60)m \(s % 60)s" }
        return "\(s)s"
    }
}
