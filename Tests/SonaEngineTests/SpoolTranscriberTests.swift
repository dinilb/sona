import NotesKit
import XCTest

@testable import SonaEngine

/// Audio not yet in a note, transcribed on demand for the MCP server. No models: a stand-in "hears" each second of
/// audio as one word, telling the voices apart by loudness (a sine at 0.1 is "alpha", at 0.2 "bravo", at 0.4
/// "charlie": words unlike each other, so the Mac's echo filter never takes one for another).
final class SpoolTranscriberTests: XCTestCase {
    var home: URL!
    var previousHome: String?
    var spool: Spool!

    override func setUp() {
        previousHome = ProcessInfo.processInfo.environment["SONA_HOME"]
        home = FileManager.default.temporaryDirectory.appendingPathComponent("sona-spool-mcp-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        setenv("SONA_HOME", home.path, 1)  // anything logged goes here, never to the real log
        spool = Spool(dir: home.appendingPathComponent("Spool"))
    }

    override func tearDown() {
        if let previousHome { setenv("SONA_HOME", previousHome, 1) } else { unsetenv("SONA_HOME") }
        try? FileManager.default.removeItem(at: home)
    }

    /// Who's talking at second `t`: "alpha" and "bravo" take turns every 10 s, with a quiet second at 296 s and 596 s (the
    /// pieces should end there, the quietest moments within 10 s of 300 s and 600 s).
    static func voice(at t: Int) -> String? {
        if t == 296 || t == 596 { return nil }
        return t % 20 < 10 ? "alpha" : "bravo"
    }

    /// One second of a 440 Hz sine.
    static let tone: [Float] = (0..<16_000).map { Float(sin(2 * Double.pi * 440 * Double($0) / 16_000)) }

    static func samples(seconds: Range<Int>, voice: (Int) -> String?) -> [Float] {
        var out: [Float] = []
        out.reserveCapacity(seconds.count * 16_000)
        for t in seconds {
            let amp: Float = switch voice(t) { case "alpha": 0.1; case "bravo": 0.2; case "charlie": 0.4; default: 0 }
            out += amp == 0 ? [Float](repeating: 0, count: 16_000) : tone.map { $0 * amp }
        }
        return out
    }

    /// Hears one word per second that isn't quiet, named by its loudness, its speakers numbered by first appearance
    /// in the piece (as the diarizer does), each with its own voice.
    final class StandIn: @unchecked Sendable {  // `calls` only under `lock`
        private let lock = NSLock()
        private var count = 0
        let delay: Double

        init(delay: Double = 0) { self.delay = delay }

        var calls: Int { lock.withLock { count } }

        func hear(_ samples: [Float]) async -> SpoolTranscriber.Voiced {
            lock.withLock { count += 1 }
            if delay > 0 { try? await Task.sleep(nanoseconds: UInt64(delay * 1e9)) }
            var words: [Word] = []
            var order: [String] = []
            for second in 0..<(samples.count / 16_000) {
                let window = samples[(second * 16_000)..<((second + 1) * 16_000)]
                let rms = (window.reduce(0) { $0 + $1 * $1 } / 16_000).squareRoot()
                guard rms >= 0.003 else { continue }
                let who = rms < 0.1 ? "alpha" : rms < 0.2 ? "bravo" : "charlie"
                if !order.contains(who) { order.append(who) }
                words.append(Word(word: who, start: Double(second) + 0.1, end: Double(second) + 0.6, speaker: "Speaker \(order.firstIndex(of: who)! + 1)"))
            }
            var voices: [String: [Float]] = [:]
            for (i, who) in order.enumerated() {
                voices["Speaker \(i + 1)"] = who == "alpha" ? [1, 0.1, 0] : who == "bravo" ? [0.1, 1, 0] : [0, 0.1, 1]
            }
            return SpoolTranscriber.Voiced(words: words, voices: voices)
        }
    }

    /// A recording as the Listener leaves it while it's going: its WAV's header still says 0 bytes.
    func record(_ id: String, seconds: Int, mac: (offset: Int, seconds: Int)? = nil) throws -> (WavFile, WavFile?) {
        var entry = SpoolEntry(id: id, startedAt: Date().addingTimeInterval(-Double(seconds)))
        let wav = try WavFile(creating: spool.wav(id))
        try wav.append(Self.samples(seconds: 0..<seconds, voice: Self.voice))
        var macWav: WavFile?
        if let mac {
            entry.mac = SpoolEntry.MacTrack(offset: Double(mac.offset))
            macWav = try WavFile(creating: spool.macWav(id))
            try macWav?.append(Self.samples(seconds: 0..<mac.seconds) { _ in "charlie" })
        }
        spool.save(entry)
        return (wav, macWav)
    }

    func transcriber(_ standIn: StandIn) async -> SpoolTranscriber {
        let t = SpoolTranscriber(spool: Spool(dir: spool.dir, create: false), model: "v2")
        await t.useStandIn { await standIn.hear($0) }
        return t
    }

    func testPiecesEndAtQuietMomentsAndSpeakersAreJoinedAcrossThem() async throws {
        _ = try record("r1", seconds: 620)
        let standIn = StandIn()
        let t = await transcriber(standIn)
        let slice = await t.slice(id: "r1", from: 0, to: 10_000, deadline: .distantFuture)
        XCTAssertNil(slice.error)
        XCTAssertEqual(slice.duration, 620, accuracy: 0.01)
        XCTAssertEqual(slice.to, 620, accuracy: 0.01)
        XCTAssertTrue(slice.complete)
        XCTAssertEqual(standIn.calls, 3, "pieces end at 296 s, 596 s and the end")
        let mic = try XCTUnwrap(SpoolTranscriber.Track(url: spool.wav("r1"), offset: 0))
        let edges = await t.boundaries(mic)
        XCTAssertEqual(edges, [0, 296 * 16_000, 596 * 16_000, 620 * 16_000])
        // Every "alpha" is one person and every "bravo" the other, in every piece (the second piece starts with "bravo").
        XCTAssertEqual(slice.words.count, 618)
        for w in slice.words {
            XCTAssertEqual(w.speaker, w.word == "alpha" ? "Speaker 1" : "Speaker 2", "\(w.word) at \(w.start)")
            XCTAssertEqual(w.word, Self.voice(at: Int(w.start)), "timed from the recording's start")
        }
        XCTAssertTrue(slice.words.contains { $0.word == "bravo" && abs($0.start - 297.1) < 0.01 })
    }

    func testAskingAgainOnlyTranscribesWhatsNew() async throws {
        let (wav, _) = try record("r1", seconds: 620)
        let standIn = StandIn()
        let t = await transcriber(standIn)
        _ = await t.slice(id: "r1", from: 0, to: 10_000, deadline: .distantFuture)
        XCTAssertEqual(standIn.calls, 3)
        _ = await t.slice(id: "r1", from: 0, to: 10_000, deadline: .distantFuture)
        XCTAssertEqual(standIn.calls, 3, "nothing new: all from memory")
        try wav.append(Self.samples(seconds: 620..<650, voice: Self.voice))
        let grown = await t.slice(id: "r1", from: 0, to: 10_000, deadline: .distantFuture)
        XCTAssertEqual(standIn.calls, 4, "only the last piece again")
        XCTAssertEqual(grown.duration, 650, accuracy: 0.01)
        XCTAssertEqual(grown.words.last?.start ?? 0, 649.1, accuracy: 0.01)
        // A stretch inside it: only its words, with the speakers numbered from its own start.
        let part = await t.slice(id: "r1", from: 310, to: 330, deadline: .distantFuture)
        XCTAssertEqual(standIn.calls, 4)
        XCTAssertEqual(part.words.map(\.word), Array(repeating: "bravo", count: 10) + Array(repeating: "alpha", count: 10))
        XCTAssertEqual(Set(part.words.prefix(10).map(\.speaker)), ["Speaker 1"])
    }

    /// "Delete the last N minutes" cuts the spool's audio: what was cut is never shown again, even from memory.
    func testCutAudioIsNeverShownAgain() async throws {
        _ = try record("r1", seconds: 620)
        let standIn = StandIn()
        let t = await transcriber(standIn)
        let before = await t.slice(id: "r1", from: 0, to: 10_000, deadline: .distantFuture)
        XCTAssertTrue(before.words.contains { $0.start > 400 })
        try WavFile.repair(spool.wav("r1"), truncatingTo: 200)
        let after = await t.slice(id: "r1", from: 0, to: 10_000, deadline: .distantFuture)
        XCTAssertEqual(after.duration, 200, accuracy: 0.01)
        XCTAssertFalse(after.words.isEmpty)
        XCTAssertTrue(after.words.allSatisfy { $0.start < 200 })
        // Replaced with other audio of the same length: heard again, not served from memory.
        let calls = standIn.calls
        let other = try WavFile(creating: spool.dir.appendingPathComponent("replacement.wav"))
        try other.append(Self.samples(seconds: 0..<200) { _ in "charlie" })
        XCTAssertEqual(rename(other.url.path, spool.wav("r1").path), 0)
        let replaced = await t.slice(id: "r1", from: 0, to: 10_000, deadline: .distantFuture)
        XCTAssertEqual(standIn.calls, calls + 1)
        XCTAssertEqual(Set(replaced.words.map(\.word)), ["charlie"])
        // Gone (it became a note): says so.
        spool.remove("r1")
        let gone = await t.slice(id: "r1", from: 0, to: 10_000, deadline: .distantFuture)
        XCTAssertNotNil(gone.error)
        XCTAssertTrue(gone.words.isEmpty)
    }

    /// Out of time: the newest piece first, the rest between requests.
    func testOutOfTimeTheNewestComesFirstAndTheRestFollows() async throws {
        _ = try record("r1", seconds: 620)
        let standIn = StandIn(delay: 0.3)
        let t = await transcriber(standIn)
        let first = await t.slice(id: "r1", from: 0, to: 10_000, deadline: Date().addingTimeInterval(0.1))
        XCTAssertEqual(standIn.calls, 1)
        XCTAssertFalse(first.complete)
        XCTAssertEqual(first.doneFrom, 596, accuracy: 0.01)
        XCTAssertTrue(first.words.allSatisfy { $0.start >= 596 })
        let hasLeft = await t.hasLeftover
        XCTAssertTrue(hasLeft)
        var more = await t.continueLeftover()
        XCTAssertTrue(more)
        more = await t.continueLeftover()
        XCTAssertTrue(more)
        more = await t.continueLeftover()
        XCTAssertFalse(more, "all done")
        let second = await t.slice(id: "r1", from: 0, to: 10_000, deadline: Date())
        XCTAssertTrue(second.complete)
        XCTAssertEqual(second.words.count, 618)
        XCTAssertEqual(standIn.calls, 3)
    }

    /// The Mac's own audio is its own track: labelled Mac audio, at its place in the recording.
    func testTheMacTrackIsMergedIn() async throws {
        _ = try record("r1", seconds: 120, mac: (offset: 30, seconds: 40))
        let t = await transcriber(StandIn())
        let slice = await t.slice(id: "r1", from: 0, to: 10_000, deadline: .distantFuture)
        let mac = slice.words.filter { $0.track == Tracks.mac }
        XCTAssertEqual(mac.count, 40)
        XCTAssertEqual(Set(mac.map(\.speaker)), [Tracks.macLabel])
        XCTAssertEqual(mac.first?.start ?? 0, 30.1, accuracy: 0.01)
        XCTAssertEqual(Set(slice.words.filter { $0.track == nil }.map(\.speaker)), ["Speaker 1", "Speaker 2"])
        XCTAssertEqual(slice.words.filter { $0.track == nil }.count, 120)
    }

    /// It only ever reads: the spool's files are exactly as they were.
    func testTheSpoolIsNeverChanged() async throws {
        _ = try record("r1", seconds: 400, mac: (offset: 10, seconds: 50))
        func snapshot() throws -> [String: String] {
            var out: [String: String] = [:]
            for name in try FileManager.default.contentsOfDirectory(atPath: spool.dir.path) {
                let url = spool.dir.appendingPathComponent(name)
                let attrs = try FileManager.default.attributesOfItem(atPath: url.path)
                let data = try Data(contentsOf: url)
                out[name] = "\(data.hashValue) \(attrs[.size] ?? 0) \(attrs[.modificationDate] ?? 0) \(attrs[.posixPermissions] ?? 0)"
            }
            return out
        }
        let before = try snapshot()
        let t = await transcriber(StandIn())
        _ = await t.slice(id: "r1", from: 0, to: 10_000, deadline: .distantFuture)
        _ = await t.slice(id: "r1", from: 100, to: 200, deadline: Date())
        XCTAssertEqual(try snapshot(), before)
    }

    // MARK: SpeakerLink

    func testVoicesAreMatchedAcrossPieces() {
        let a: [Float] = [1, 0, 0], b: [Float] = [0, 1, 0], c: [Float] = [0, 0, 1]
        func w(_ s: String, _ t: Double) -> Word { Word(word: s, start: t, end: t + 0.5, speaker: s) }
        // The second piece names them the other way round, and brings someone new.
        let linked = SpeakerLink.link([
            .init(words: [w("Speaker 1", 0), w("Speaker 2", 1)], voices: ["Speaker 1": a, "Speaker 2": b]),
            .init(words: [w("Speaker 1", 2), w("Speaker 2", 3), w("Speaker 3", 4)], voices: ["Speaker 1": b, "Speaker 2": a, "Speaker 3": c]),
        ])
        XCTAssertEqual(linked.map(\.speaker), ["Speaker 1", "Speaker 2", "Speaker 2", "Speaker 1", "Speaker 3"])
    }

    func testTwoSpeakersOfOnePieceAreNeverOnePerson() {
        let a: [Float] = [1, 0.1, 0], alsoA: [Float] = [1, 0.2, 0], b: [Float] = [0, 1, 0]
        func w(_ s: String, _ t: Double) -> Word { Word(word: "x", start: t, end: t + 0.5, speaker: s) }
        let linked = SpeakerLink.link([
            .init(words: [w("Speaker 1", 0), w("Speaker 2", 1)], voices: ["Speaker 1": a, "Speaker 2": b]),
            // Both sound like the first piece's Speaker 1: only the closer one is them.
            .init(words: [w("Speaker 1", 2), w("Speaker 2", 3)], voices: ["Speaker 1": alsoA, "Speaker 2": SpeakerLink.unit([1, 0.5, 0.4])]),
        ])
        XCTAssertEqual(linked.map(\.speaker), ["Speaker 1", "Speaker 2", "Speaker 1", "Speaker 3"])
    }

    func testAPieceWithoutVoicesGoesToWhoeverSpokeLast() {
        let a: [Float] = [1, 0, 0], b: [Float] = [0, 1, 0]
        func w(_ s: String, _ t: Double) -> Word { Word(word: "x", start: t, end: t + 0.5, speaker: s) }
        let linked = SpeakerLink.link([
            .init(words: [w("Speaker 1", 0), w("Speaker 2", 1)], voices: ["Speaker 1": a, "Speaker 2": b]),
            .init(words: [w("Speaker 1", 2)], voices: [:]),
        ])
        XCTAssertEqual(linked.map(\.speaker), ["Speaker 1", "Speaker 2", "Speaker 2"])
    }
}
