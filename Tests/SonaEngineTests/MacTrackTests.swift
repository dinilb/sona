import NotesKit
import XCTest

@testable import SonaEngine

/// This Mac's audio in the notes pipeline: lined up with the mic's, spooled as its own WAV, transcribed on its own
/// and merged into one note.
final class MacTrackTests: XCTestCase {
    var home: URL!
    var previousHome: String?
    let t0 = Date(timeIntervalSince1970: 1_790_000_000)

    override func setUp() {
        previousHome = ProcessInfo.processInfo.environment["SONA_HOME"]
        home = FileManager.default.temporaryDirectory.appendingPathComponent("sona-mac-track-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        setenv("SONA_HOME", home.path, 1)
    }

    override func tearDown() {
        if let previousHome { setenv("SONA_HOME", previousHome, 1) } else { unsetenv("SONA_HOME") }
        try? FileManager.default.removeItem(at: home)
    }

    // MARK: lining the two up

    func frame(_ value: Float, _ n: Int = 1_600) -> [Float] { [Float](repeating: value, count: n) }

    /// With nothing playing, a mic frame goes straight on, with no Mac audio.
    func testWithoutMacAudioMicFramesGoStraightThrough() {
        var a = TrackAligner()
        a.addMic(frame(0.1), at: t0)
        let out = a.ready(now: t0.addingTimeInterval(0.1))
        XCTAssertEqual(out.count, 1)
        XCTAssertNil(out[0].mac)
    }

    /// While the Mac plays, a mic frame waits for the Mac's audio of the same moment and goes on with it.
    func testMicFramesWaitForTheMacsAudioOfTheSameMoment() {
        var a = TrackAligner()
        a.addMac(frame(0.5), at: t0, now: t0.addingTimeInterval(0.1))
        a.addMic(frame(0.1), at: t0)
        a.addMic(frame(0.1), at: t0.addingTimeInterval(0.1))
        let first = a.ready(now: t0.addingTimeInterval(0.12))
        XCTAssertEqual(first.count, 1, "the second frame waits for the Mac's next 100 ms")
        XCTAssertEqual(first[0].mac, frame(0.5))
        a.addMac(frame(0.6), at: t0.addingTimeInterval(0.1), now: t0.addingTimeInterval(0.21))
        let second = a.ready(now: t0.addingTimeInterval(0.21))
        XCTAssertEqual(second.map(\.mac), [frame(0.6)])
    }

    /// The Mac's audio a few samples off (capture times jitter) still lines up sample for sample.
    func testJitterNeverRepeatsOrSkipsASample() {
        var a = TrackAligner()
        let mac = (0..<4_800).map { Float($0) }
        a.addMac(Array(mac[0..<1_600]), at: t0, now: t0)
        a.addMac(Array(mac[1_600..<3_200]), at: t0.addingTimeInterval(0.1003), now: t0)
        a.addMac(Array(mac[3_200...]), at: t0.addingTimeInterval(0.1996), now: t0)
        a.addMic(frame(0, 2_400), at: t0)
        a.addMic(frame(0, 2_400), at: t0.addingTimeInterval(0.1498))
        let out = a.ready(now: t0.addingTimeInterval(0.31))
        XCTAssertEqual(out.compactMap(\.mac).flatMap { $0 }, mac)
    }

    /// The Mac late by more than `hold`: the mic goes on with silence for the Mac's part.
    func testAStalledMacNeverHoldsTheMicUpLong() {
        var a = TrackAligner()
        a.addMac(frame(0.5), at: t0, now: t0)
        a.addMic(frame(0.1), at: t0)
        a.addMic(frame(0.1), at: t0.addingTimeInterval(0.1))
        XCTAssertEqual(a.ready(now: t0.addingTimeInterval(0.25)).count, 1)
        let late = a.ready(now: t0.addingTimeInterval(0.2 + TrackAligner.hold))
        XCTAssertEqual(late.map(\.mac), [frame(0)])
    }

    /// The Mac stopped playing: once its last audio is handed out, mic frames go on without any.
    func testTheMacStoppingEndsItsTrack() {
        var a = TrackAligner()
        a.addMac(frame(0.5), at: t0, now: t0)
        a.addMic(frame(0.1), at: t0)
        XCTAssertNotNil(a.ready(now: t0.addingTimeInterval(0.1)).first?.mac)
        a.addMic(frame(0.1), at: t0.addingTimeInterval(3))
        let after = a.ready(now: t0.addingTimeInterval(3 + TrackAligner.idle))
        XCTAssertEqual(after.count, 1)
        XCTAssertNil(after[0].mac)
        XCTAssertFalse(a.macFlowing(now: t0.addingTimeInterval(3 + TrackAligner.idle)))
    }

    /// The Mac starting part way through a mic frame: silence before it.
    func testTheMacStartingMidFrame() {
        var a = TrackAligner()
        a.addMac(frame(0.5, 800), at: t0.addingTimeInterval(0.05), now: t0)
        a.addMic(frame(0.1), at: t0)
        let out = a.ready(now: t0.addingTimeInterval(0.11))
        XCTAssertEqual(out.first?.mac, frame(0, 800) + frame(0.5, 800))
    }

    // MARK: one note from two tracks

    func transcript(_ words: [Word], duration: Double) -> Transcript {
        Transcript(
            startedAt: t0, duration: duration, text: words.map(\.word).joined(separator: " "), words: words,
            turns: [], asrSeconds: 0.1, diarizationSeconds: 0.1, model: "test")
    }

    func words(_ text: String, from start: Double, speaker: String, step: Double = 0.3) -> [Word] { Self.words(text, from: start, speaker: speaker, step: step) }

    static func words(_ text: String, from start: Double, speaker: String, step: Double = 0.3) -> [Word] {
        text.split(separator: " ").enumerated().map {
            Word(word: String($1), start: start + Double($0) * step, end: start + Double($0) * step + 0.25, speaker: speaker)
        }
    }

    /// The mic heard the room and the video through the speakers; the Mac track heard the video. One note: the room's
    /// words, the video's as "Mac audio", the mic's copies flagged, speakers numbered without gaps, in time order.
    func testCombineTheTwoTracks() {
        let mic = transcript(
            words("did you see the video", from: 0.5, speaker: "Speaker 1")
                + words("welcome back to the channel today", from: 4.08, speaker: "Speaker 2")
                + words("that's the ferry", from: 7.5, speaker: "Speaker 3"),
            duration: 10)
        // The Mac's WAV starts 3 s into the conversation.
        let mac = transcript(words("welcome back to the channel today", from: 1.0, speaker: "Speaker 1"), duration: 6)
        let r = MacTrackMerge.combine(mic: mic, mac: mac, offset: 3, micCurve: [], macCurve: [])
        XCTAssertEqual(r.echoes, 6)
        XCTAssertEqual(r.macWords, 6)
        let lines = Lines.from(r.transcript.words)
        XCTAssertEqual(lines.map(\.speaker), ["Speaker 1", "Mac audio", "Speaker 2"])
        XCTAssertEqual(lines.map(\.text), ["did you see the video", "welcome back to the channel today", "that's the ferry"])
        XCTAssertEqual(lines[1].start, 4.0, accuracy: 0.001)
        XCTAssertEqual(r.transcript.speakers, ["Speaker 1", "Mac audio", "Speaker 2"])
        XCTAssertEqual(r.transcript.words.filter { $0.echo == true }.count, 6, "flagged in the .json, not deleted")
        XCTAssertEqual(r.transcript.text, "did you see the video welcome back to the channel today that's the ferry")
        XCTAssertEqual(r.transcript.duration, 10)
    }

    // MARK: the spool and the processor

    func wav(_ url: URL, seconds: Double) throws {
        let f = try WavFile(creating: url)
        try f.append((0..<Int(seconds * 16_000)).map { Float(sin(Double($0) * 0.05)) * 0.3 })
        try f.finish()
    }

    /// The Mac's WAV sits beside the mic's: never a conversation of its own, and it goes when the entry goes.
    func testTheMacWavIsPartOfItsConversation() throws {
        let spool = Spool()
        var e = SpoolEntry(id: Spool.newID(for: t0), startedAt: t0)
        e.mac = SpoolEntry.MacTrack(offset: 1)
        try wav(spool.wav(e.id), seconds: 3)
        try wav(spool.macWav(e.id), seconds: 2)
        spool.save(e)
        XCTAssertEqual(spool.pending().map(\.id), [e.id])
        XCTAssertEqual(spool.load(e.id)?.mac, SpoolEntry.MacTrack(offset: 1))
        spool.fail(e.id)
        XCTAssertEqual(spool.failedCount(), 1)
        XCTAssertTrue(FileManager.default.fileExists(atPath: spool.failedDir().appendingPathComponent(e.id + ".mac.wav").path))
        let other = SpoolEntry(id: Spool.newID(for: t0), startedAt: t0)
        try wav(spool.wav(other.id), seconds: 1)
        try wav(spool.macWav(other.id), seconds: 1)
        spool.remove(other.id)
        XCTAssertFalse(FileManager.default.fileExists(atPath: spool.macWav(other.id).path))
    }

    /// A conversation with the Mac's audio becomes one note with both, the Mac's audio deleted with the mic's.
    func testTheProcessorWritesBothTracks() async throws {
        let spool = Spool()
        var e = SpoolEntry(id: Spool.newID(for: t0), startedAt: t0)
        e.mac = SpoolEntry.MacTrack(offset: 2, speechSeconds: 2)
        e.closed = true
        e.speechEnd = 6
        e.speechSeconds = 4
        try wav(spool.wav(e.id), seconds: 6)
        try wav(spool.macWav(e.id), seconds: 4)
        spool.save(e)
        let settings = Settings(notesFolder: home.appendingPathComponent("Notes").path)
        let p = Processor(spool: spool, settings: settings)
        let macURL = spool.macWav(e.id)
        await p.useTranscriber { url, startedAt in
            if url == macURL {
                return Transcript(
                    startedAt: startedAt, duration: 4,
                    text: "", words: Self.words("thanks for watching everyone", from: 0.5, speaker: "Speaker 1"), turns: [],
                    asrSeconds: 0, diarizationSeconds: 0, model: "test")
            }
            return Transcript(
                startedAt: startedAt, duration: 6, text: "",
                words: Self.words("hello there", from: 0.2, speaker: "Speaker 1")
                    + Self.words("thanks for watching everyone", from: 2.55, speaker: "Speaker 2"),
                turns: [], asrSeconds: 0, diarizationSeconds: 0, model: "test")
        }
        await p.enqueue(e.id)
        await p.waitUntilIdle()
        let written = await p.written
        let note = try XCTUnwrap(written.first)
        let text = try String(contentsOf: note, encoding: .utf8)
        XCTAssertTrue(text.contains("Speaker 1: hello there\n"), text)
        XCTAssertTrue(text.contains("Mac audio: thanks for watching everyone\n"), text)
        XCTAssertFalse(text.contains("Speaker 2"), text)
        let side = try JSONDecoder().decode(
            NoteWriter.Sidecar.self, from: Data(contentsOf: note.deletingPathExtension().appendingPathExtension("json")))
        XCTAssertEqual(side.words.filter { $0.track == Tracks.mac }.count, 4)
        XCTAssertEqual(side.words.filter { $0.echo == true }.count, 4)
        XCTAssertFalse(FileManager.default.fileExists(atPath: macURL.path), "deleted once the note is written")
    }

    /// "Delete the last N minutes" cuts the Mac's audio at the same moment.
    func testForgettingCutsTheMacsAudioToo() async throws {
        let spool = Spool()
        var e = SpoolEntry(id: Spool.newID(for: t0), startedAt: t0)
        e.mac = SpoolEntry.MacTrack(offset: 1)
        e.closed = true
        e.speechEnd = 4
        e.speechSeconds = 4
        try wav(spool.wav(e.id), seconds: 4)
        try wav(spool.macWav(e.id), seconds: 3)
        spool.save(e)
        let p = Processor(spool: spool, settings: Settings(notesFolder: home.appendingPathComponent("Notes").path))
        _ = await p.forget(from: t0.addingTimeInterval(2.5))
        XCTAssertEqual(WavFile.duration(of: spool.wav(e.id)), 2.5, accuracy: 0.001)
        XCTAssertEqual(WavFile.duration(of: spool.macWav(e.id)), 1.5, accuracy: 0.001)
        _ = await p.forget(from: t0.addingTimeInterval(0.5))
        XCTAssertFalse(FileManager.default.fileExists(atPath: spool.macWav(e.id).path), "it started after the cut")
    }

    /// The Mac speaking counts as the Mac playing; with a call on, it doesn't.
    func testTheMacSpeakingCountsTowardsMedia() {
        var t = Playback.Tally()
        for _ in 0..<9 { t.add(speechWith: Playback.Sample(playing: true, call: false)) }
        t.add(speechWith: Playback.Sample(playing: false, call: false))
        XCTAssertEqual(Playback.mediaReason(fraction: t.fraction) != nil, true)
        var call = Playback.Tally()
        for _ in 0..<10 { call.add(speechWith: Playback.Sample(playing: true, call: true)) }
        XCTAssertNil(Playback.mediaReason(fraction: call.fraction))
    }
}
