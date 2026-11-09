import XCTest

@testable import LiveCore

final class TranscriptTests: XCTestCase {
    /// A long day: words get trimmed while speakers keep resolving, and every returned index stays valid.
    func testLongSessionTrimsWithoutCrashing() {
        let t = LiveTranscript()
        for i in 0..<10_000 {
            let start = Double(i) * 0.3
            t.add([LiveToken(text: " w\(i)", start: start)])
            t.speakers.append([Int8](repeating: Int8(i / 50 % 2), count: 30))
            for index in t.resolveSpeakers() {
                XCTAssertGreaterThanOrEqual(index - t.dropped, 0)
                XCTAssertLessThan(index - t.dropped, t.words.count)
            }
        }
        XCTAssertLessThanOrEqual(t.words.count, 8_000)
        XCTAssertGreaterThan(t.dropped, 0)
        XCTAssertFalse(t.lines().isEmpty)
    }

    /// `lines()` keeps the settled lines from last time: it must always give exactly what building every line from
    /// scratch gives, through words arriving in pieces, speakers resolving late, deletes and a long day's trimming.
    func testKeptLinesMatchAFullRebuild() {
        struct Shown: Equatable {
            var id: Int, speaker: Int?, settled: Bool, text: String, start: Double, end: Double
            init(_ l: LiveLine) { (id, speaker, settled, text, start, end) = (l.id, l.speaker, l.settled, l.text, l.start, l.end) }
        }
        var rng = SeededGenerator(seed: 7)
        for speakersOn in [true, false] {
            let t = LiveTranscript()
            var time = 0.0, frames = 0
            let steps = speakersOn ? 12_000 : 2_000
            for step in 0..<steps {
                var tokens: [LiveToken] = []
                for _ in 0..<Int.random(in: 0...3, using: &rng) {
                    // Mostly short gaps, sometimes a pause long enough for a new line; some pieces continue a word.
                    time += Double.random(in: 0...1, using: &rng) < 0.12 ? Double.random(in: 0.8...2, using: &rng) : Double.random(in: 0.05...0.4, using: &rng)
                    let piece = Int.random(in: 0..<10, using: &rng)
                    tokens.append(LiveToken(text: piece == 0 ? " " : piece < 3 ? "s" : " w\(step)", start: time))
                }
                t.add(tokens)
                if speakersOn, Bool.random(using: &rng) {
                    // The diarizer runs a little behind; the speaker changes every few seconds.
                    let upTo = Int((time - Double.random(in: 0...1.5, using: &rng)) / SpeakerTimeline.frameSeconds)
                    if upTo > frames {
                        t.speakers.append((frames..<upTo).map { Int8($0 / 350 % 3) - ($0 % 900 < 40 ? Int8(1) : 0) })
                        frames = upTo
                    }
                    t.resolveSpeakers()
                }
                if step % 1_500 == 1_499, t.words.count > 10 { t.removeWords(from: t.words.count - Int.random(in: 1...10, using: &rng)) }
                // Like the app (every update), and now and then against a full rebuild.
                let check = step % 20 == 0 || step == steps - 1
                let kept = speakersOn || check ? t.lines() : []
                if check {
                    XCTAssertEqual(t.lines().map(Shown.init), t.lines(from: 0).map(Shown.init), "step \(step)")
                    XCTAssertEqual(kept.map(Shown.init), t.lines(from: 0).map(Shown.init), "step \(step)")
                }
            }
            if speakersOn { XCTAssertGreaterThan(t.dropped, 0, "long enough to be trimmed") }
        }
    }

    func testLinesSplitOnSpeakerAndPause() {
        let t = LiveTranscript()
        t.add([LiveToken(text: " hey", start: 0), LiveToken(text: " there", start: 0.3)])
        t.add([LiveToken(text: " hi", start: 1.0)])
        t.add([LiveToken(text: " later", start: 3.0)])
        // Speaker 0 for the first second, speaker 1 after.
        t.speakers.append([Int8](repeating: 0, count: 80) + [Int8](repeating: 1, count: 300))
        t.resolveSpeakers()
        let lines = t.lines()
        XCTAssertEqual(lines.map(\.text), ["hey there", "hi", "later"])
        XCTAssertEqual(lines.map(\.speaker), [0, 1, 1])
    }

    /// "Delete the last N minutes": the words go, speakers keep resolving, and what comes next is a new word.
    func testRemoveWordsFromTheEnd() {
        let t = LiveTranscript()
        t.add([LiveToken(text: " keep", start: 0), LiveToken(text: " this", start: 0.3), LiveToken(text: " gone", start: 5), LiveToken(text: " too", start: 5.3)])
        t.speakers.append([Int8](repeating: 0, count: 700))
        t.resolveSpeakers()
        t.removeWords(from: 2)
        XCTAssertEqual(t.lines().map(\.text), ["keep this"])
        t.add([LiveToken(text: "next", start: 9)])  // a word's second piece, its first piece deleted
        t.speakers.append([Int8](repeating: 1, count: 300))
        XCTAssertEqual(t.resolveSpeakers(), 2..<3)
        XCTAssertEqual(t.words.map(\.text), ["keep", "this", "next"])
        t.removeWords(from: 0)
        XCTAssertEqual(t.words.count, 0)
        t.removeWords(from: 5)  // nothing there: no change
        XCTAssertTrue(t.lines().isEmpty)
    }

    /// "Delete the last N minutes" while words are still being decoded: ones that began in the deleted time arrive
    /// after the click, and are dropped too (every piece of them); words said after it aren't.
    func testWordsArrivingForDeletedTimeAreDropped() {
        let t = LiveTranscript()
        t.add([LiveToken(text: " keep", start: 0), LiveToken(text: " this", start: 0.3), LiveToken(text: " gone", start: 5)])
        t.forget(from: 2, during: 4..<8)
        XCTAssertEqual(t.words.map(\.text), ["keep", "this"])
        t.add([LiveToken(text: " sec", start: 6), LiveToken(text: "ret", start: 6.2), LiveToken(text: " ", start: 6.5)])
        t.add([LiveToken(text: "40", start: 6.6)])
        t.add([LiveToken(text: ",000", start: 6.8)])  // the rest of a dropped word, in the next update
        t.add([LiveToken(text: " after", start: 8.5), LiveToken(text: "wards", start: 8.7)])
        XCTAssertEqual(t.words.map(\.text), ["keep", "this", "afterwards"])
        t.forget(from: t.words.count, during: 9..<9)  // nothing to forget
        t.add([LiveToken(text: " more", start: 9)])
        XCTAssertEqual(t.lines().map(\.text), ["keep this", "afterwards more"])
    }

    /// The other way round, for a delete: the session second heard at a date, never past a gap.
    func testWallClockFindsTheSessionSecondOfADate() {
        let t0 = Date(timeIntervalSince1970: 1_790_000_000)
        var wall = WallClock()
        XCTAssertNil(wall.seconds(at: t0))
        wall.mark(0, at: t0)
        wall.mark(10, at: t0.addingTimeInterval(10))
        wall.mark(20, at: t0.addingTimeInterval(3_600 + 20))  // after an hour asleep
        XCTAssertEqual(wall.seconds(at: t0.addingTimeInterval(5))!, 5, accuracy: 0.001)
        XCTAssertEqual(wall.seconds(at: t0.addingTimeInterval(1_800))!, 20, accuracy: 0.001, "asleep: where the audio picks up")
        XCTAssertEqual(wall.seconds(at: t0.addingTimeInterval(3_625))!, 25, accuracy: 0.001)
        XCTAssertEqual(wall.seconds(at: t0.addingTimeInterval(-5))!, 0, accuracy: 0.001)
        // With no mark since the gap (no words yet), it runs on past where the audio picked up again...
        var quiet = WallClock()
        quiet.mark(3_600, at: t0)
        XCTAssertEqual(quiet.seconds(at: t0.addingTimeInterval(3_304))!, 6_904, accuracy: 0.001)
        // ...but the audio's own clock has a mark per buffer, gaps included: it stops where the audio picked up.
        let audio = AudioClock()
        audio.mark(index: 0, hostTime: 1_000)
        audio.mark(index: 3_600 * 16_000, hostTime: 4_600)
        audio.mark(index: 3_600 * 16_000 + 1_600, hostTime: 8_200)  // the mic closed for an hour after 0.1 s
        XCTAssertEqual(audio.seconds(atHost: 2_000)!, 1_000, accuracy: 0.001)
        XCTAssertEqual(audio.seconds(atHost: 7_904)!, 3_600.1, accuracy: 0.001, "closed: where the audio picks up")
        XCTAssertEqual(audio.seconds(atHost: 8_204)!, 3_604.1, accuracy: 0.001, "after the last mark it runs on")
    }

    func testNumbersStartTheirOwnWord() {
        let t = LiveTranscript()
        t.add([LiveToken(text: " wants", start: 0), LiveToken(text: " ", start: 0.2), LiveToken(text: "40,000", start: 0.3)])
        XCTAssertEqual(t.words.map(\.text), ["wants", "40,000"])
    }

    /// Lines keep their real times across a gap (sleep, a pause, a closed mic): session time only counts audio.
    func testWallClockKeepsRealTimesAcrossGaps() {
        let t0 = Date(timeIntervalSince1970: 1_790_000_000)
        var wall = WallClock()
        XCTAssertNil(wall.date(atSeconds: 1))
        wall.mark(0, at: t0)
        wall.mark(0.5, at: t0.addingTimeInterval(0.5))  // too close, skipped
        wall.mark(10, at: t0.addingTimeInterval(10))
        // Session second 20 was heard after an hour asleep.
        wall.mark(20, at: t0.addingTimeInterval(3_600 + 20))
        XCTAssertEqual(wall.date(atSeconds: 5)!.timeIntervalSince(t0), 5, accuracy: 0.001)
        XCTAssertEqual(wall.date(atSeconds: 15)!.timeIntervalSince(t0), 15, accuracy: 0.001)
        XCTAssertEqual(wall.date(atSeconds: 25)!.timeIntervalSince(t0), 3_625, accuracy: 0.001)
        // Bounded.
        var small = WallClock()
        small.keep = 10
        for i in 0..<25 { small.mark(Double(i * 2), at: t0.addingTimeInterval(Double(i * 2))) }
        XCTAssertEqual(small.date(atSeconds: 48)!.timeIntervalSince(t0), 48, accuracy: 0.001)
    }

    /// The live pass's speaker count for a stretch of time (the hint a finished conversation passes on).
    func testSpeakerLogCountsWhoSpokeInARange() {
        let t0 = Date(timeIntervalSince1970: 1_790_000_000)
        var log = SpeakerLog()
        // 0-10 s: speaker 0, 10-20 s: speaker 1, one stray word by speaker 2 at 15 s, 100-110 s: speaker 3.
        for i in 0..<20 { log.add(slot: 0, at: t0.addingTimeInterval(Double(i) * 0.5)) }
        for i in 0..<20 { log.add(slot: i == 10 ? 2 : 1, at: t0.addingTimeInterval(10 + Double(i) * 0.5)) }
        for i in 0..<20 { log.add(slot: 3, at: t0.addingTimeInterval(100 + Double(i) * 0.5)) }
        XCTAssertEqual(log.count(from: t0, to: t0.addingTimeInterval(25)), 2, "the stray word isn't a person")
        XCTAssertEqual(log.count(from: t0, to: t0.addingTimeInterval(25), minWords: 1), 3)
        XCTAssertEqual(log.count(from: t0.addingTimeInterval(95), to: t0.addingTimeInterval(120)), 1)
        XCTAssertEqual(log.count(from: t0.addingTimeInterval(30), to: t0.addingTimeInterval(90)), 0)
        // Runs, not words: 60 words make 5 entries.
        XCTAssertEqual(log.runs.count, 5)
        // Old runs are dropped.
        log.add(slot: 0, at: t0.addingTimeInterval(4 * 3600))
        XCTAssertEqual(log.runs.count, 1)
    }
}

/// Repeatable random numbers for tests (SplitMix64).
struct SeededGenerator: RandomNumberGenerator {
    var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}
