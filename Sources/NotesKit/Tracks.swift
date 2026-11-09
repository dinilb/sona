import Foundation

/// A conversation can have two tracks: the mic (the room) and what this Mac played (a video, a call, through a
/// Core Audio tap). Each is transcribed and split into speakers on its own; here they become one transcript.
/// The Mac's voices are never a person in the room: they're "Mac audio" (or "Mac audio 1", "Mac audio 2" when
/// there are several), and the room keeps "Speaker 1", "Speaker 2".
public enum Tracks {
    /// `Word.track` for what this Mac played.
    public static let mac = "mac"
    public static let macLabel = "Mac audio"

    /// The Mac's voices: "Mac audio" when there's one, else "Mac audio 1", "Mac audio 2" ... (`index` from 0).
    public static func macName(_ index: Int, of count: Int) -> String {
        count <= 1 ? macLabel : "\(macLabel) \(index + 1)"
    }

    /// The Mac track's words and turns (speakers as its diarizer named them), moved by `offset` seconds (where its
    /// audio starts in the conversation), marked as the Mac's and labelled in order of first appearance.
    public static func labelMac(_ words: [Word], turns: [Turn], offset: Double) -> ([Word], [Turn]) {
        var order: [String] = []
        for w in words where !order.contains(w.speaker) { order.append(w.speaker) }
        for t in turns where !order.contains(t.speaker) { order.append(t.speaker) }
        let speaking = Set(words.map(\.speaker)).count
        func name(_ s: String) -> String { macName(order.firstIndex(of: s) ?? 0, of: speaking) }
        let w = words.map { Word(word: $0.word, start: $0.start + offset, end: $0.end + offset, speaker: name($0.speaker), track: mac) }
        let t = turns.filter { s in words.contains { $0.speaker == s.speaker } }
            .map { Turn(speaker: name($0.speaker), start: $0.start + offset, end: $0.end + offset) }
        return (w, t)
    }

    /// The mic's speakers numbered again by first appearance among the words that are shown, so dropping echo
    /// words never leaves a gap ("Speaker 1, Speaker 3"). A speaker heard only in echo words comes after.
    public static func renumberMic(_ words: [Word], turns: [Turn]) -> ([Word], [Turn]) {
        var order: [String] = []
        for w in words where w.shown && !order.contains(w.speaker) { order.append(w.speaker) }
        for w in words where !order.contains(w.speaker) { order.append(w.speaker) }
        for t in turns where !order.contains(t.speaker) { order.append(t.speaker) }
        func name(_ s: String) -> String { "Speaker \((order.firstIndex(of: s) ?? 0) + 1)" }
        var renamed = words
        for i in renamed.indices { renamed[i].speaker = name(words[i].speaker) }
        return (renamed, turns.map { Turn(speaker: name($0.speaker), start: $0.start, end: $0.end) })
    }

    /// One transcript from the two tracks, ordered by time a whole utterance at a time (the note's own line rules
    /// within each track), so two people talking over each other stay two whole lines instead of interleaving word
    /// by word, and a word that came out late still sits in its own line. Utterances are ordered by their first
    /// shown word; on a tie the mic's comes first.
    public static func merge(mic: [Word], mac: [Word]) -> [Word] {
        let a = utterances(mic), b = utterances(mac)
        var out: [Word] = []
        out.reserveCapacity(mic.count + mac.count)
        var i = 0, j = 0
        while i < a.count || j < b.count {
            if j == b.count || i < a.count && a[i].start <= b[j].start {
                out += a[i].words
                i += 1
            } else {
                out += b[j].words
                j += 1
            }
        }
        return out
    }

    /// A word's end counts as at most this long after its start when looking for pauses: the batch model's last
    /// word before a silence often "ends" when the next word starts, many seconds later.
    static let wordCap = 1.0
    /// A pause this long ends an utterance (shorter than a note line's, so the other track's words in it land there).
    static let pause = 1.0

    /// One track's words split where its note lines would be, and at pauses of `pause`. Echo words never start or
    /// split one: they stay with the words around them, in their place.
    static func utterances(_ words: [Word]) -> [(start: Double, words: [Word])] {
        var out: [(start: Double, words: [Word])] = []
        var current: [Word] = []
        var first: Word?, last: Word?
        func flush() {
            guard !current.isEmpty else { return }
            out.append((first?.start ?? current[0].start, current))
            current = []
            first = nil
        }
        for w in words {
            if w.shown {
                let paused = last.map { w.start - min($0.end, $0.start + wordCap) >= pause } ?? false
                if let f = first, let l = last, paused || Lines.splits(f, l, w) { flush() }
                if first == nil { first = w }
                last = w
            }
            current.append(w)
        }
        flush()
        return out
    }
}
