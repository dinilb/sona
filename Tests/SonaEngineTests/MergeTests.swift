import FluidAudio
import NotesKit
import XCTest

@testable import SonaEngine

final class MergeTests: XCTestCase {
    private func word(_ w: String, _ start: Double, _ end: Double) -> WordTiming {
        WordTiming(word: w, startTime: start, endTime: end)
    }

    private func turn(_ id: String, _ start: Float, _ end: Float) -> TimedSpeakerSegment {
        TimedSpeakerSegment(speakerId: id, embedding: [], startTimeSeconds: start, endTimeSeconds: end, qualityScore: 1)
    }

    func testNoTurnsGivesEveryoneSpeakerOne() {
        let (words, turns) = Merge.assignSpeakers(words: [word("hi", 0, 0.5), word("there", 3, 3.5)], segments: [])
        XCTAssertEqual(words.map(\.speaker), ["Speaker 1", "Speaker 1"])
        XCTAssertEqual(turns, [])
    }

    func testNoWords() {
        let (words, turns) = Merge.assignSpeakers(words: [], segments: [turn("a", 0, 1)])
        XCTAssertEqual(words, [])
        XCTAssertEqual(turns, [Turn(speaker: "Speaker 1", start: 0, end: 1)])
    }

    /// Diarizer ids are arbitrary; names follow who speaks first in time, not the order segments arrive in.
    func testSpeakersNamedInOrderOfFirstAppearance() {
        let segments = [turn("spk7", 4, 6), turn("spk2", 0, 2), turn("spk7", 2, 4), turn("spk0", 6, 8)]
        let (_, turns) = Merge.assignSpeakers(words: [], segments: segments)
        XCTAssertEqual(turns.map(\.speaker), ["Speaker 1", "Speaker 2", "Speaker 2", "Speaker 3"])
        XCTAssertEqual(turns.map(\.start), [0, 2, 4, 6])
    }

    func testWordGoesToTheTurnItOverlapsMost() {
        let segments = [turn("a", 0, 2), turn("b", 2, 4)]
        let (words, _) = Merge.assignSpeakers(
            words: [word("mostlyA", 1.5, 2.25), word("mostlyB", 1.75, 2.5), word("insideB", 3, 3.5)], segments: segments)
        XCTAssertEqual(words.map(\.speaker), ["Speaker 1", "Speaker 2", "Speaker 2"])
        XCTAssertEqual(words.map(\.word), ["mostlyA", "mostlyB", "insideB"])
        XCTAssertEqual(words[0].start, 1.5)
        XCTAssertEqual(words[0].end, 2.25)
    }

    /// Parakeet's times run late: a word in the gap right after the previous one stays with that speaker,
    /// even when the next turn is nearer.
    func testGapWordWithoutPauseKeepsPreviousSpeaker() {
        let segments = [turn("a", 0, 2), turn("b", 2.375, 4)]
        let (words, _) = Merge.assignSpeakers(
            words: [word("end", 1.5, 2), word("tail", 2.125, 2.375)], segments: segments)
        XCTAssertEqual(words.map(\.speaker), ["Speaker 1", "Speaker 1"])
    }

    /// After a real pause, a gap word goes to the nearest turn instead.
    func testGapWordAfterPauseGoesToNearestTurn() {
        let segments = [turn("a", 0, 2), turn("b", 3, 4)]
        let (words, _) = Merge.assignSpeakers(
            words: [word("end", 1.5, 2), word("early", 2.5, 2.875)], segments: segments)
        XCTAssertEqual(words.map(\.speaker), ["Speaker 1", "Speaker 2"])
    }

    /// The very first word in a gap has no previous word: nearest turn.
    func testFirstWordBeforeAnyTurnGoesToNearest() {
        let segments = [turn("a", 1, 2), turn("b", 5, 6)]
        let (words, _) = Merge.assignSpeakers(words: [word("um", 0, 0.5), word("late", 7, 7.5)], segments: segments)
        XCTAssertEqual(words.map(\.speaker), ["Speaker 1", "Speaker 2"])
    }

    func testTouchingButNotOverlappingIsAGap() {
        // Ends exactly where "b" starts: zero overlap, so continuity/nearest decide, not overlap.
        let segments = [turn("a", 0, 1), turn("b", 2, 3)]
        let (words, _) = Merge.assignSpeakers(words: [word("x", 1.75, 2)], segments: segments)
        XCTAssertEqual(words.map(\.speaker), ["Speaker 2"])
    }

    /// Too little speech for the diarizer: one speaker, and no words means nothing to write.
    func testOneSpeakerWhenTheDiarizerHeardNoSpeech() {
        let words = [WordTiming(word: "okay", startTime: 1.0, endTime: 1.3), WordTiming(word: "thanks", startTime: 1.4, endTime: 1.8)]
        let (assigned, turns) = Merge.oneSpeaker(words)
        XCTAssertEqual(assigned.map(\.speaker), ["Speaker 1", "Speaker 1"])
        XCTAssertEqual(turns.count, 1)
        XCTAssertEqual(turns.first?.start, 1.0)
        XCTAssertEqual(turns.first?.end, 1.8)
        XCTAssertTrue(Merge.oneSpeaker([]).0.isEmpty)
    }
}
