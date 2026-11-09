import Foundation
import NotesKit

/// Speakers across pieces of one recording transcribed apart (`SpoolTranscriber` does a few minutes at a time, so a
/// long conversation isn't transcribed again from the start on every call). Each piece's diarizer numbers its own
/// speakers; here a piece's speaker becomes an earlier piece's when their voices match, and a new one otherwise.
///
/// Pure, so it's tested without audio. A voice is the diarizer's embedding for that speaker, made unit length.
public enum SpeakerLink {
    public struct Piece: Sendable {
        /// Speakers as the piece's diarizer named them ("Speaker 1", ...).
        public var words: [Word]
        /// Each speaker's voice, unit length. A speaker without one (too little speech to embed) can't be matched.
        public var voices: [String: [Float]]

        public init(words: [Word], voices: [String: [Float]]) {
            self.words = words
            self.voices = voices
        }
    }

    /// Two voices this alike (cosine) are the same person. The diarizer's own clustering joins single embeddings
    /// closer than 0.6 apart (Euclidean, unit length: cosine 0.82); a speaker's average over minutes varies less, but
    /// pieces are minutes apart. Measured 9 Nov 2026: one person across 5-minute pieces of a real 20-minute recording,
    /// 0.89 to 0.97; the test clips' two `say` voices, 0.15.
    public static let threshold: Float = 0.6

    /// The pieces' words in order, with each piece's speakers renamed to the recording's ("Speaker 1", "Speaker 2",
    /// in order of first appearance). One piece's speakers are always different people from each other: two of them
    /// are never matched to the same earlier speaker.
    public static func link(_ pieces: [Piece], threshold: Float = threshold) -> [Word] {
        var known: [(voice: [Float], weight: Float)] = []
        var out: [Word] = []
        var lastGlobal: Int?
        for piece in pieces {
            let locals = speakers(of: piece)
            var map: [String: Int] = [:]
            // Every pairing that's alike enough, most alike first, each side used once.
            var pairs: [(local: String, global: Int, similarity: Float)] = []
            for local in locals {
                guard let voice = piece.voices[local] else { continue }
                for (g, k) in known.enumerated() {
                    let s = cosine(voice, k.voice)
                    if s >= threshold { pairs.append((local, g, s)) }
                }
            }
            pairs.sort { $0.similarity > $1.similarity }
            var taken = Set<Int>()
            for pair in pairs where map[pair.local] == nil && !taken.contains(pair.global) {
                map[pair.local] = pair.global
                taken.insert(pair.global)
            }
            for local in locals where map[local] == nil {
                if piece.voices[local] == nil, piece.voices.isEmpty, let last = lastGlobal, !taken.contains(last) {
                    // No voice at all (a word or two the diarizer couldn't place): most likely whoever spoke last.
                    map[local] = last
                    taken.insert(last)
                    continue
                }
                known.append((piece.voices[local] ?? [], 0))
                map[local] = known.count - 1
            }
            // Each match moves that speaker's voice toward this piece's, by how much they said here.
            for local in locals {
                guard let g = map[local], let voice = piece.voices[local], !voice.isEmpty else { continue }
                let said = Float(piece.words.filter { $0.speaker == local }.reduce(0) { $0 + max(0, $1.end - $1.start) })
                let weight = max(said, 0.1)
                if known[g].voice.isEmpty {
                    known[g] = (voice, weight)
                } else {
                    let total = known[g].weight + weight
                    let merged = zip(known[g].voice, voice).map { ($0 * known[g].weight + $1 * weight) / total }
                    known[g] = (unit(merged), total)
                }
            }
            for var w in piece.words {
                guard let g = map[w.speaker] else { continue }
                w.speaker = "Speaker \(g + 1)"
                lastGlobal = g
                out.append(w)
            }
        }
        // Numbered by first appearance in the words, as a note's are.
        var order: [String] = []
        for w in out where !order.contains(w.speaker) { order.append(w.speaker) }
        return out.map { w in
            var w = w
            w.speaker = "Speaker \((order.firstIndex(of: w.speaker) ?? 0) + 1)"
            return w
        }
    }

    /// A piece's speakers in order of first appearance, those with words first.
    static func speakers(of piece: Piece) -> [String] {
        var order: [String] = []
        for w in piece.words where !order.contains(w.speaker) { order.append(w.speaker) }
        return order
    }

    static func cosine(_ a: [Float], _ b: [Float]) -> Float {
        guard a.count == b.count, !a.isEmpty else { return -1 }
        var dot: Float = 0, na: Float = 0, nb: Float = 0
        for i in a.indices {
            dot += a[i] * b[i]
            na += a[i] * a[i]
            nb += b[i] * b[i]
        }
        guard na > 0, nb > 0 else { return -1 }
        return dot / (na.squareRoot() * nb.squareRoot())
    }

    static func unit(_ v: [Float]) -> [Float] {
        let n = v.reduce(0) { $0 + $1 * $1 }.squareRoot()
        return n > 0 ? v.map { $0 / n } : v
    }
}
