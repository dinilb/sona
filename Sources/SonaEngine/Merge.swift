import FluidAudio
import Foundation
import NotesKit

enum Merge {
    /// Give every word the speaker whose diarizer turn overlaps it most. A word that falls in a gap
    /// between turns keeps the previous word's speaker if there was no pause before it (Parakeet's
    /// word times run slightly late, so the last word of a turn often lands in the gap); otherwise
    /// it goes to the nearest turn. Speakers are renamed "Speaker 1, 2, ..." in order of
    /// first appearance.
    static func assignSpeakers(words: [WordTiming], segments: [TimedSpeakerSegment]) -> ([Word], [Turn]) {
        let sorted = segments.sorted { $0.startTimeSeconds < $1.startTimeSeconds }
        var names: [String: String] = [:]
        for segment in sorted where names[segment.speakerId] == nil {
            names[segment.speakerId] = "Speaker \(names.count + 1)"
        }
        let turns = sorted.map {
            Turn(
                speaker: names[$0.speakerId]!, start: Double($0.startTimeSeconds),
                end: Double($0.endTimeSeconds))
        }

        var assigned: [Word] = []
        for w in words {
            var name = overlapSpeaker(for: w, in: turns)
            if name == nil, let prev = assigned.last, w.startTime - prev.end <= continuityGap {
                name = prev.speaker
            }
            let speaker = name ?? nearestSpeaker(for: w, in: turns)
            assigned.append(Word(word: w.word, start: w.startTime, end: w.endTime, speaker: speaker))
        }
        return (assigned, turns)
    }

    /// No diarization to go on (too little speech): every word is Speaker 1.
    static func oneSpeaker(_ words: [WordTiming]) -> ([Word], [Turn]) {
        let assigned = words.map { Word(word: $0.word, start: $0.startTime, end: $0.endTime, speaker: "Speaker 1") }
        guard let first = assigned.first, let last = assigned.last else { return ([], []) }
        return (assigned, [Turn(speaker: "Speaker 1", start: first.start, end: last.end)])
    }

    /// Max pause (seconds) between two words for the second to count as the same breath.
    static let continuityGap = 0.15

    private static func overlapSpeaker(for word: WordTiming, in turns: [Turn]) -> String? {
        var best: Turn?
        var bestOverlap = 0.0
        for turn in turns {
            let overlap = min(word.endTime, turn.end) - max(word.startTime, turn.start)
            if overlap > bestOverlap {
                bestOverlap = overlap
                best = turn
            }
        }
        return best?.speaker
    }

    private static func nearestSpeaker(for word: WordTiming, in turns: [Turn]) -> String {
        guard !turns.isEmpty else { return "Speaker 1" }
        let mid = (word.startTime + word.endTime) / 2
        let nearest = turns.min { distance(mid, $0) < distance(mid, $1) }!
        return nearest.speaker
    }

    private static func distance(_ t: Double, _ turn: Turn) -> Double {
        if t < turn.start { return turn.start - t }
        if t > turn.end { return t - turn.end }
        return 0
    }

}
