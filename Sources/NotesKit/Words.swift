import Foundation

/// One line of "Words it should know": spellings the model writes (one or more, comma-separated) and how to write
/// them instead. "Sonar, Sonnar, Sonor" → "Sona".
public struct WordFix: Codable, Equatable, Hashable, Sendable {
    public var heard: String
    public var write: String

    public init(heard: String, write: String) {
        self.heard = heard
        self.write = write
    }
}

/// The words list, ready to use on dictation, the live transcript and new notes. Whole words (or phrases) only,
/// any case: "sonar" and "SONAR" match, "sonars" doesn't. An apostrophe or hyphen inside a word doesn't end it, so
/// "won" never matches in "won't" or "won-ton"; only a possessive 's may follow ("sonar's" → "Sona's"). The written
/// form is used as typed, except that a capital first letter where the match had one (a sentence start) is kept
/// when the written form is all lowercase.
// @unchecked: NSRegularExpression is immutable and safe to share between threads.
public struct WordFixer: @unchecked Sendable {
    private let regex: NSRegularExpression?
    /// Heard spelling (`key`) → written form.
    private let written: [String: String]

    public static let none = WordFixer([])

    public init(_ fixes: [WordFix]) {
        var written: [String: String] = [:]
        var spellings: [[Substring]] = []
        for fix in fixes {
            let write = fix.write.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !write.isEmpty else { continue }  // a line still being typed does nothing
            for heard in fix.heard.split(separator: ",") {
                let words = heard.split(whereSeparator: \.isWhitespace)
                let key = Self.key(words.joined(separator: " "))
                guard !words.isEmpty, written[key] == nil else { continue }  // the first line for a spelling wins
                written[key] = write
                spellings.append(words)
            }
        }
        // Longest first: "whisper flow" before "whisper".
        let patterns = spellings.sorted { $0.joined(separator: " ").count > $1.joined(separator: " ").count }
            .map { $0.map { NSRegularExpression.escapedPattern(for: String($0)) }.joined(separator: #"\s+"#) }
        self.written = written
        // Not right after a letter or digit, or an apostrophe or hyphen that follows one; not right before a letter
        // or digit, or an apostrophe or hyphen that comes before one (but 's, ending the word, may follow).
        let before = #"(?<![\p{L}\p{N}])(?<![\p{L}\p{N}]['’-])"#
        let after = #"(?![\p{L}\p{N}])(?!-[\p{L}\p{N}])(?!['’](?![sS](?![\p{L}\p{N}]))[\p{L}\p{N}])"#
        regex = patterns.isEmpty ? nil : try? NSRegularExpression(
            pattern: before + "(?:" + patterns.joined(separator: "|") + ")" + after, options: [.caseInsensitive])
    }

    public var isEmpty: Bool { regex == nil }

    static func key(_ s: String) -> String {
        s.split(whereSeparator: \.isWhitespace).joined(separator: " ").lowercased()
    }

    /// The written form for what was matched.
    func replacement(for found: String) -> String {
        guard let write = written[Self.key(found)] else { return found }
        if let first = found.first, first.isUppercase, write == write.lowercased(), let w = write.first, w.isLowercase {
            return w.uppercased() + write.dropFirst()
        }
        return write
    }

    public func apply(_ text: String) -> String {
        guard let regex else { return text }
        let ns = text as NSString
        let matches = regex.matches(in: text, range: NSRange(location: 0, length: ns.length))
        guard !matches.isEmpty else { return text }
        var out = ""
        var at = 0
        for m in matches {
            out += ns.substring(with: NSRange(location: at, length: m.range.location - at))
            out += replacement(for: ns.substring(with: m.range))
            at = NSMaxRange(m.range)
        }
        return out + ns.substring(from: at)
    }

    /// The same on a note's words, so its lines and its .json agree. A match across words ("whisper flow") becomes
    /// one word spanning their times, with the first one's speaker.
    public func apply(_ words: [Word]) -> [Word] {
        guard let regex, !words.isEmpty else { return words }
        var text = ""
        var starts: [Int] = []  // where each word begins in `text` (UTF-16)
        for (i, w) in words.enumerated() {
            if i > 0 { text += " " }
            starts.append((text as NSString).length)
            text += w.word
        }
        let ns = text as NSString
        let matches = regex.matches(in: text, range: NSRange(location: 0, length: ns.length))
        guard !matches.isEmpty else { return words }
        func end(_ i: Int) -> Int { starts[i] + (words[i].word as NSString).length }

        var out: [Word] = []
        var i = 0, k = 0
        while i < words.count {
            while k < matches.count, matches[k].range.location < starts[i] { k += 1 }  // never cut into a gap
            guard k < matches.count, matches[k].range.location < end(i) else {
                out.append(words[i])
                i += 1
                continue
            }
            // Word i holds a match: take in every word the matches starting here reach.
            var j = i
            let first = k
            while k < matches.count, matches[k].range.location < end(j) {
                while j + 1 < words.count, starts[j + 1] < NSMaxRange(matches[k].range) { j += 1 }
                k += 1
            }
            var piece = ""
            var at = starts[i]
            for m in matches[first..<k] {
                piece += ns.substring(with: NSRange(location: at, length: m.range.location - at))
                piece += replacement(for: ns.substring(with: m.range))
                at = NSMaxRange(m.range)
            }
            piece += ns.substring(with: NSRange(location: at, length: end(j) - at))
            out.append(
                Word(word: piece, start: words[i].start, end: words[j].end, speaker: words[i].speaker, track: words[i].track, echo: words[i].echo))
            i = j + 1
        }
        return out
    }
}
