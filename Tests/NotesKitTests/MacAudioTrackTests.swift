import XCTest

@testable import NotesKit

/// This Mac's audio as its own track: the mic's echoes of it found and flagged, the Mac's voices labelled, the two
/// tracks merged by time, and the .json keeping which track each word came from.
final class MacAudioTrackTests: XCTestCase {
    typealias T = EchoFilter.Timed

    /// Words every 0.3 s from `start`.
    func timed(_ text: String, from start: Double, step: Double = 0.3) -> [T] {
        text.split(separator: " ").enumerated().map { T(String($1), start + Double($0) * step) }
    }

    func word(_ w: String, _ start: Double, _ speaker: String, track: String? = nil, echo: Bool? = nil) -> Word {
        Word(word: w, start: start, end: start + 0.25, speaker: speaker, track: track, echo: echo)
    }

    // MARK: the echo filter

    /// The mic hearing the video through the speakers, a little late: every copied word goes.
    func testTheMicsCopyOfTheMacIsAnEcho() {
        let mac = timed("welcome back to the channel today we are touring the harbour", from: 4)
        let mic = timed("welcome back to the channel today we are touring the harbour", from: 4.08)
        XCTAssertEqual(EchoFilter.echoes(mic: mic, mac: mac), Array(repeating: true, count: mic.count))
    }

    /// Room speech over the video stays, even with a common word ("the") the video says at the same moment.
    func testRoomSpeechOverTheVideoStays() {
        let mac = timed("today we are touring the new harbour office in brisbane", from: 5.6)
        // The mic: the echo's first four words, then someone in the room over the rest.
        let mic = timed("today we are touring", from: 5.65) + timed("that's the building near the ferry", from: 6.9)
        let flags = EchoFilter.echoes(mic: mic, mac: mac)
        XCTAssertEqual(flags, [true, true, true, true, false, false, false, false, false, false])
    }

    /// Someone repeating the video's words a moment after it said them is a person, not an echo.
    func testAPhraseRepeatedAfterTheVideoStays() {
        let mac = timed("makes forty cups an hour", from: 16.4)
        let mic = timed("makes forty cups an hour", from: 16.45) + timed("forty cups an hour", from: 18.3)
        XCTAssertEqual(EchoFilter.echoes(mic: mic, mac: mac), [true, true, true, true, true, false, false, false, false])
    }

    /// Two words in common aren't a run.
    func testTwoWordsInCommonAreNotEnough() {
        let mac = timed("and the river", from: 10)
        let mic = timed("and the", from: 10.05) + timed("cat sat down", from: 12)
        XCTAssertEqual(EchoFilter.echoes(mic: mic, mac: mac), [false, false, false, false, false])
    }

    /// One word mis-heard inside a run goes with it.
    func testAMisheardWordInsideARunGoes() {
        let mac = timed("the kitchen has a coffee machine", from: 15)
        let mic = timed("the kitchen has a toffee machine", from: 15.05)
        XCTAssertEqual(EchoFilter.echoes(mic: mic, mac: mac), Array(repeating: true, count: 6))
        let garbled = timed("the kitchen has gotta coffee machine", from: 15.05)
        XCTAssertEqual(EchoFilter.echoes(mic: garbled, mac: mac), Array(repeating: true, count: 6))
    }

    /// A long word, exactly the Mac's and within half a second, is an echo on its own.
    func testADistinctiveWordOnItsOwn() {
        let mac = [T("office", 7.3), T("in", 7.6), T("Brisbane.", 7.8)]
        XCTAssertEqual(EchoFilter.echoes(mic: [T("ferry", 7.4), T("Brisbane", 8.0)], mac: mac), [false, true])
        XCTAssertEqual(EchoFilter.echoes(mic: [T("Brisbane", 9.0)], mac: mac), [false], "too late to be the speakers")
        XCTAssertEqual(EchoFilter.echoes(mic: [T("in", 7.6)], mac: mac), [false], "too short to tell")
    }

    /// Where the loudness gate says the mic was the Mac's sound, one twin is enough.
    func testTheLoudnessGateAllowsSingleTwins() {
        let mac = timed("and the river", from: 10)
        let mic = timed("and the", from: 10.05)
        XCTAssertEqual(EchoFilter.echoes(mic: mic, mac: mac, confirmed: [9.0..<11.5]), [true, true])
        XCTAssertEqual(EchoFilter.echoes(mic: mic, mac: mac, confirmed: [20.0..<21.5]), [false, false])
    }

    func testNoMacWordsMeansNoEchoes() {
        XCTAssertEqual(EchoFilter.echoes(mic: timed("hello there", from: 0), mac: []), [false, false])
    }

    func testWordsMatchLikeTranscribedTwice() {
        XCTAssertTrue(EchoFilter.similar("harbour", "harbor"))
        XCTAssertTrue(EchoFilter.similar(EchoFilter.normalized("Station,"), "station"))
        XCTAssertTrue(EchoFilter.similar(EchoFilter.normalized("40,000"), "40000"))
        XCTAssertFalse(EchoFilter.similar("the", "she"))
        XCTAssertFalse(EchoFilter.similar("coffee", "kitchen"))
    }

    // MARK: the loudness gate

    /// A syllable-like loudness curve: bursts and gaps, `seconds` long, from `seed`.
    func curve(seconds: Double, seed: UInt64) -> [Float] {
        var rng = seed
        var out: [Float] = []
        while Double(out.count) * Loudness.frameSeconds < seconds {
            rng = rng &* 6364136223846793005 &+ 1442695040888963407
            let loud = (rng >> 33) % 3 != 0
            let level: Float = loud ? -20 - Float((rng >> 40) % 10) : -80
            out += Array(repeating: level, count: 8 + Int((rng >> 50) % 12))
        }
        return out
    }

    func testTheMicFollowingTheMacsLoudnessIsConfirmed() {
        let mac = curve(seconds: 9, seed: 7)
        // The mic: the same, 6 frames (60 ms) late and 10 dB down.
        let mic = [Float](repeating: -80, count: 6) + mac.map { $0 - 10 }
        let windows = EchoGate.confirmed(mic: mic, mac: mac)
        XCTAssertGreaterThanOrEqual(windows.count, 4)
        // Someone else talking: nothing confirmed.
        XCTAssertEqual(EchoGate.confirmed(mic: curve(seconds: 9, seed: 99), mac: mac), [])
        // The Mac silent: nothing to compare.
        XCTAssertEqual(EchoGate.confirmed(mic: mic, mac: [Float](repeating: Loudness.floor, count: mac.count)), [])
    }

    func testLoudnessCurve() {
        let tone = (0..<1_600).map { Float(sin(Double($0) * 0.3)) * 0.5 }
        let c = Loudness.curve(tone)
        XCTAssertEqual(c.count, 10)
        XCTAssertEqual(Double(c[3]), 20 * log10(0.5 / 2.squareRoot()), accuracy: 0.5)
        XCTAssertEqual(Loudness.curve([Float](repeating: 0, count: 160)), [Loudness.floor])
    }

    // MARK: labels, numbering, merging

    /// The Mac's voices are "Mac audio" (or numbered when there are several), moved to conversation time; never a
    /// room speaker.
    func testTheMacsVoicesAreLabelled() {
        let one = Tracks.labelMac([word("hi", 0, "Speaker 1"), word("there", 1, "Speaker 1")], turns: [], offset: 5)
        XCTAssertEqual(one.0.map(\.speaker), ["Mac audio", "Mac audio"])
        XCTAssertEqual(one.0.map(\.track), ["mac", "mac"])
        XCTAssertEqual(one.0.map(\.start), [5, 6])
        let two = Tracks.labelMac(
            [word("a", 0, "Speaker 2"), word("b", 1, "Speaker 1"), word("c", 2, "Speaker 2")],
            turns: [Turn(speaker: "Speaker 2", start: 0, end: 1), Turn(speaker: "Speaker 1", start: 1, end: 2)], offset: 0)
        XCTAssertEqual(two.0.map(\.speaker), ["Mac audio 1", "Mac audio 2", "Mac audio 1"])
        XCTAssertEqual(two.1.map(\.speaker), ["Mac audio 1", "Mac audio 2"])
    }

    /// The room's speakers are numbered by who's shown first: a voice heard only in echoes comes last, and never
    /// leaves a gap.
    func testTheRoomsSpeakersAreNumberedAgainWithoutEchoes() {
        let words = [
            word("welcome", 0, "Speaker 1", echo: true), word("hi", 1, "Speaker 2"), word("yes", 2, "Speaker 3"),
            word("back", 3, "Speaker 1", echo: true),
        ]
        let (renamed, turns) = Tracks.renumberMic(words, turns: [Turn(speaker: "Speaker 3", start: 2, end: 3)])
        XCTAssertEqual(renamed.map(\.speaker), ["Speaker 3", "Speaker 1", "Speaker 2", "Speaker 3"])
        XCTAssertEqual(turns.map(\.speaker), ["Speaker 2"])
    }

    /// Both tracks in one note, in order by when each line began: talk over the video stays a whole line after the
    /// video's, and a Mac line after a pause lands where it belongs.
    func testTwoTracksMergeByTime() {
        let mic = [
            word("did", 0.2, "Speaker 1"), word("you", 0.5, "Speaker 1"), word("see", 0.8, "Speaker 1"),
            word("welcome", 4.0, "Speaker 2", echo: true), word("back", 4.3, "Speaker 2", echo: true),
            word("that's", 6.4, "Speaker 2"), word("the", 6.7, "Speaker 2"), word("ferry", 7.0, "Speaker 2"),
            word("forty", 18.5, "Speaker 1"), word("cups", 18.8, "Speaker 1"),
        ]
        // The Mac's last word before a long gap "ends" when the next one starts (as the batch model times it).
        var mac = [
            word("welcome", 3.9, "Mac audio", track: "mac"), word("back", 4.2, "Mac audio", track: "mac"),
            word("brisbane", 8.0, "Mac audio", track: "mac"),
            word("kitchen", 15.0, "Mac audio", track: "mac"), word("hour", 17.8, "Mac audio", track: "mac"),
        ]
        mac[2].end = 15.0
        let merged = Tracks.merge(mic: mic, mac: mac)
        XCTAssertEqual(merged.count, mic.count + mac.count, "nothing dropped, echoes included")
        let lines = Lines.from(merged)
        XCTAssertEqual(lines.map(\.speaker), ["Speaker 1", "Mac audio", "Speaker 2", "Mac audio", "Speaker 1"])
        // (The Mac's lines after the room's are one line again: nobody spoke between them.)
        XCTAssertEqual(lines.map(\.text), ["did you see", "welcome back", "that's the ferry", "brisbane kitchen hour", "forty cups"])
        XCTAssertEqual(lines.map(\.start), lines.map(\.start).sorted())
    }

    /// A late word in a track stays with its own line, and a tie goes to the mic.
    func testLateWordsAndTies() {
        let mic = [word("a", 1, "Speaker 1"), word("b", 1.3, "Speaker 1")]
        let mac = [word("x", 1, "Mac audio", track: "mac"), word("late", 1.4, "Mac audio", track: "mac")]
        XCTAssertEqual(Tracks.merge(mic: mic, mac: mac).map(\.word), ["a", "b", "x", "late"])
        XCTAssertEqual(Tracks.merge(mic: [], mac: mac).map(\.word), ["x", "late"])
        XCTAssertEqual(Tracks.merge(mic: mic, mac: []).map(\.word), ["a", "b"])
    }

    // MARK: notes

    /// Echo words are kept in the .json (flagged) but never in the note's lines, its speakers or its text.
    func testEchoWordsAreFlaggedNotShown() {
        let words = [word("hello", 0, "Speaker 1"), word("welcome", 0.4, "Speaker 2", echo: true), word("there", 0.6, "Speaker 1")]
        XCTAssertEqual(Lines.from(words).map(\.text), ["hello there"])
        let t = Transcript(
            startedAt: Date(), duration: 1, text: "hello there", words: words, turns: [], asrSeconds: 0, diarizationSeconds: 0,
            model: "test")
        XCTAssertEqual(t.speakers, ["Speaker 1"])
        XCTAssertEqual(t.cut(at: 0.5).text, "hello")
    }

    /// The .json records each word's track (and echo flag), and reads back the same; a mic word without them stays
    /// as before (no new keys), so older notes are unchanged.
    func testTrackFieldRoundTripsThroughTheJSON() throws {
        let words = [
            word("hi", 0, "Speaker 1"), word("welcome", 1, "Speaker 1", echo: true),
            word("welcome", 1, "Mac audio", track: Tracks.mac),
        ]
        let data = try JSONEncoder().encode(words)
        XCTAssertEqual(try JSONDecoder().decode([Word].self, from: data), words)
        let plain = String(data: try JSONEncoder().encode(words[0]), encoding: .utf8)!
        XCTAssertFalse(plain.contains("track") || plain.contains("echo"), plain)
        let old = #"{"word":"hi","start":0,"end":0.25,"speaker":"Speaker 1"}"#
        let decoded = try JSONDecoder().decode(Word.self, from: Data(old.utf8))
        XCTAssertNil(decoded.track)
        XCTAssertNil(decoded.echo)
    }

    /// Written through NoteWriter: the note shows both tracks, the .json keeps every word with its track.
    func testNoteWriterKeepsTracks() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("mac-track-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let words = [
            word("Did", 0, "Speaker 1"), word("you", 0.3, "Speaker 1"), word("see", 0.6, "Speaker 1"),
            word("Welcome", 4, "Speaker 1", echo: true),
            word("Welcome", 4, "Mac audio", track: Tracks.mac), word("back", 4.3, "Mac audio", track: Tracks.mac),
        ]
        let t = Transcript(
            startedAt: Date(), duration: 5, text: "Did you see Welcome back", words: words, turns: [], asrSeconds: 0,
            diarizationSeconds: 0, model: "test")
        let md = try NoteWriter.write(t, to: dir)
        let text = try String(contentsOf: md, encoding: .utf8)
        XCTAssertTrue(text.contains("Speaker 1: Did you see\n"), text)
        XCTAssertTrue(text.contains("Mac audio: Welcome back\n"), text)
        XCTAssertTrue(text.contains(#"speakers: ["Speaker 1", "Mac audio"]"#), text)
        let side = try JSONDecoder().decode(
            NoteWriter.Sidecar.self, from: Data(contentsOf: md.deletingPathExtension().appendingPathExtension("json")))
        XCTAssertEqual(side.words.map(\.track), [nil, nil, nil, nil, "mac", "mac"])
        XCTAssertEqual(side.words.map(\.echo), [nil, nil, nil, true, nil, nil])
    }

    func testTheSwitchIsOffUntilTurnedOn() throws {
        XCTAssertFalse(Settings().macAudio)
        XCTAssertFalse(try JSONDecoder().decode(Settings.self, from: Data("{}".utf8)).macAudio)
        var s = Settings()
        s.macAudio = true
        XCTAssertTrue(try JSONDecoder().decode(Settings.self, from: JSONEncoder().encode(s)).macAudio)
    }
}
