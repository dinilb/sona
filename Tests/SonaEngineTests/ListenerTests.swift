import CoreML
import FluidAudio
import NotesKit
import XCTest
import os

@testable import SonaEngine

/// The conversation splitter, driven with real Silero VAD on synthetic audio: speech from macOS `say`,
/// digital silence between. Needs the VAD model (not in the repo): set SONA_TEST_HOME to a home that
/// has Models/silero-vad (default: the repo's test-home/). Skipped without it, so CI never downloads models.
final class ListenerTests: XCTestCase {
    private static let rate = 16_000
    /// Loaded once for the whole class (the model and `say` are slow).
    private static let cachedVAD = OSAllocatedUnfairLock<VadManager?>(initialState: nil)
    private static let cachedSpeech = OSAllocatedUnfairLock<[Float]?>(initialState: nil)

    private var home: URL!
    private var previousHome: String?
    private var spool: Spool!
    private var events: [Listener.Event] = []
    private let t0 = Date(timeIntervalSince1970: 1_790_000_000)

    override func setUp() async throws {
        previousHome = ProcessInfo.processInfo.environment["SONA_HOME"]
        home = FileManager.default.temporaryDirectory.appendingPathComponent("sona-listener-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        setenv("SONA_HOME", home.path, 1)
        spool = Spool(dir: home.appendingPathComponent("Spool"))
        events = []
    }

    override func tearDown() async throws {
        if let previousHome { setenv("SONA_HOME", previousHome, 1) } else { unsetenv("SONA_HOME") }
        try? FileManager.default.removeItem(at: home)
    }

    // MARK: Fixtures

    private func vad() async throws -> VadManager {
        if let v = Self.cachedVAD.withLock({ $0 }) { return v }
        let testHome = ProcessInfo.processInfo.environment["SONA_TEST_HOME"].map { URL(fileURLWithPath: $0) }
            ?? URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("test-home")
        let dir = testHome.appendingPathComponent("Models/silero-vad")
        let compiled = (try? FileManager.default.contentsOfDirectory(atPath: dir.path))?.first { $0.hasSuffix(".mlmodelc") }
        guard let compiled else { throw XCTSkip("no Silero VAD model in \(dir.path); set SONA_TEST_HOME") }
        let model = try MLModel(contentsOf: dir.appendingPathComponent(compiled))
        let v = VadManager(config: VadConfig(defaultThreshold: 0.6), vadModel: model)
        Self.cachedVAD.withLock { $0 = v }
        return v
    }

    /// About 3 s of continuous synthetic speech, 16 kHz mono.
    private func speech() throws -> [Float] {
        if let s = Self.cachedSpeech.withLock({ $0 }) { return s }
        let url = home.appendingPathComponent("speech.wav")
        let say = Process()
        say.executableURL = URL(fileURLWithPath: "/usr/bin/say")
        say.arguments = [
            "-o", url.path, "--file-format=WAVE", "--data-format=LEF32@16000",
            "The pricing page needs work before we ship it on Friday afternoon",
        ]
        try say.run()
        say.waitUntilExit()
        guard say.terminationStatus == 0 else { throw XCTSkip("macOS say couldn't synthesize speech") }
        let reader = try AudioFileReader(url: url)
        var samples: [Float] = []
        while let chunk = try reader.next() { samples += chunk }
        // Trim the synthesizer's own leading/trailing quiet so the timing below is about our silence.
        let loud = samples.indices.filter { abs(samples[$0]) > 0.02 }
        guard let first = loud.first, let last = loud.last else { throw XCTSkip("say produced silence") }
        let trimmed = Array(samples[first...last])
        Self.cachedSpeech.withLock { $0 = trimmed }
        return trimmed
    }

    private func silence(_ seconds: Double) -> [Float] { [Float](repeating: 0, count: Int(seconds * Double(Self.rate))) }

    private func listener(quiet: Double, _ configure: (inout Listener.Config) -> Void = { _ in }) async throws -> Listener {
        var config = Listener.Config(quietSeconds: quiet)
        configure(&config)
        let l = await Listener(vad: try vad(), spool: spool, config: config)
        l.onEvent = { [unowned self] in events.append($0) }
        return l
    }

    /// Feeds audio the way the mic does: 100 ms buffers with matching timestamps.
    private func feed(_ l: Listener, _ samples: [Float], from start: Date) async throws {
        let step = Self.rate / 10
        var i = 0
        while i < samples.count {
            let piece = Array(samples[i..<min(i + step, samples.count)])
            try await l.feed(piece, at: start.addingTimeInterval(Double(i) / Double(Self.rate)))
            i += step
        }
    }

    private var closed: [SpoolEntry] { events.compactMap { if case let .closed(e) = $0 { return e } else { return nil } } }
    private var opened: [Date] { events.compactMap { if case let .opened(d) = $0 { return d } else { return nil } } }
    private var discarded: [String] { events.compactMap { if case let .discarded(id) = $0 { return id } else { return nil } } }
    private var log: String { (try? String(contentsOf: Paths.logFile, encoding: .utf8)) ?? "" }
    private func duration(_ s: [Float]) -> Double { Double(s.count) / Double(Self.rate) }

    // MARK: Tests

    /// Silence, speech, then enough quiet: one conversation, opened with 1 s of pre-roll and closed 1 s after the speech.
    func testQuietClosesTheConversation() async throws {
        let l = try await listener(quiet: 3)
        let s = try speech()
        try await feed(l, silence(3) + s + silence(5), from: t0)

        XCTAssertEqual(opened.count, 1)
        XCTAssertEqual(closed.count, 1, "events: \(events)")
        let started = try XCTUnwrap(opened.first)
        XCTAssertEqual(started.timeIntervalSince(t0), 2, accuracy: 0.6, "speech at 3 s, minus 1 s of pre-roll")
        let e = try XCTUnwrap(closed.first)
        XCTAssertTrue(e.closed)
        XCTAssertEqual(e.startedAt, started)
        XCTAssertGreaterThan(e.speechSeconds, 1.5)
        XCTAssertLessThanOrEqual(e.speechSeconds, duration(s) + 0.6)
        // Audio is pre-roll + speech + 1 s after it, not the trailing quiet.
        XCTAssertEqual(e.speechEnd, 1 + duration(s) + 1, accuracy: 0.8)
        XCTAssertEqual(WavFile.duration(of: spool.wav(e.id)), e.speechEnd, accuracy: 0.001)
        let saved = try XCTUnwrap(spool.load(e.id), "the closed entry is on disk")
        XCTAssertTrue(saved.closed)
        XCTAssertEqual(saved.speechEnd, e.speechEnd)
        XCTAssertEqual(saved.startedAt.timeIntervalSince(e.startedAt), 0, accuracy: 1, "JSON keeps whole seconds")
        XCTAssertNil(l.conversationStartedAt)
        XCTAssertTrue(log.contains("closed (quiet for 3 s)"), log)
        // The speech flag went up and came back down.
        let flags = events.compactMap { if case let .speech(b) = $0 { return b } else { return nil } }
        XCTAssertEqual(flags.first, true)
        XCTAssertEqual(flags.last, false)
    }

    /// Talk quieter than the floor (-50 dBFS, fainter than anyone in the room) never wakes the voice detector, so it
    /// opens nothing; the same words at a normal level still do.
    func testTooQuietToBeInTheRoomOpensNothing() async throws {
        let l = try await listener(quiet: 2)
        let s = try speech()
        let faint = s.map { $0 * 0.002 }
        XCTAssertLessThan(Listener.rms(faint), Listener.floor)
        try await feed(l, faint + silence(3), from: t0)
        XCTAssertEqual(opened.count, 0, "events: \(events)")
        try await feed(l, s + silence(3), from: t0.addingTimeInterval(duration(faint) + 3))
        XCTAssertEqual(opened.count, 1, "events: \(events)")
    }

    /// Pauses shorter than the quiet time stay in one conversation; a longer one splits it.
    func testSplitsOnlyOnLongQuiet() async throws {
        let l = try await listener(quiet: 3)
        let s = try speech()
        try await feed(l, s + silence(1.5) + s + silence(4) + s + silence(4), from: t0)
        XCTAssertEqual(opened.count, 2, "events: \(events)")
        XCTAssertEqual(closed.count, 2)
        XCTAssertGreaterThan(closed[0].speechEnd, 2 * duration(s), "the 1.5 s pause didn't split")
        XCTAssertLessThan(closed[1].speechEnd, duration(s) + 2.5)
        XCTAssertEqual(spool.pending().count, 2)
    }

    /// Too little speech (a cough, a door): dropped, audio deleted.
    func testBlipIsDiscarded() async throws {
        let l = try await listener(quiet: 2) { $0.minSpeechSeconds = 30 }
        try await feed(l, try speech() + silence(3), from: t0)
        XCTAssertEqual(closed.count, 0)
        XCTAssertEqual(discarded.count, 1, "events: \(events)")
        XCTAssertEqual(spool.pending(), [])
        XCTAssertTrue(log.contains("dropped (quiet for 2 s)"), log)
    }

    /// Mid-conversation the entry on disk is kept up to date every 5 s, so a crash still knows where speech ended.
    func testCheckpointsWhileOpen() async throws {
        let l = try await listener(quiet: 30)
        let s = try speech()
        try await feed(l, s + s + s, from: t0)
        XCTAssertEqual(closed.count, 0)
        let pending = spool.pending()
        XCTAssertEqual(pending.count, 1)
        let e = try XCTUnwrap(pending.first)
        XCTAssertFalse(e.closed)
        XCTAssertGreaterThan(e.speechEnd, 4, "a checkpoint recorded where speech ended")
        XCTAssertGreaterThan(e.speechSeconds, 4)
        XCTAssertEqual(l.conversationStartedAt, e.startedAt)
    }

    /// A gap in the timestamps longer than the quiet time (the Mac slept) ends the conversation.
    func testLongGapInAudioCloses() async throws {
        let l = try await listener(quiet: 10)
        let s = try speech()
        try await feed(l, s, from: t0)
        XCTAssertEqual(opened.count, 1)
        try await feed(l, silence(1), from: t0.addingTimeInterval(120))
        XCTAssertEqual(closed.count, 1, "events: \(events)")
        XCTAssertTrue(log.contains("closed (gap in audio of"), log)
    }

    /// A gap over a minute (but under the quiet time) can't be filled truthfully: it ends the conversation,
    /// and speech after it starts a new one at its real time.
    func testGapOverAMinuteCloses() async throws {
        let l = try await listener(quiet: 180)
        let s = try speech()
        try await feed(l, s, from: t0)
        XCTAssertNotNil(l.openEntryID)
        XCTAssertEqual(spool.openID, l.openEntryID)
        let later = t0.addingTimeInterval(duration(s) + 90)
        try await feed(l, s, from: later)
        XCTAssertEqual(closed.count, 1, "events: \(events)")
        XCTAssertNotEqual(spool.openID, closed[0].id, "the closed one is the processor's now")
        XCTAssertEqual(opened.count, 2)
        XCTAssertEqual(opened[1].timeIntervalSince(later), 0, accuracy: 1.5)
        XCTAssertTrue(log.contains("closed (gap in audio of"), log)
    }

    /// A short gap (an engine restart) is filled with silence, so later audio keeps its true time.
    func testShortGapIsFilledWithSilence() async throws {
        let l = try await listener(quiet: 10)
        let s = try speech()
        try await feed(l, s, from: t0)
        try await feed(l, s, from: t0.addingTimeInterval(duration(s) + 3))
        try l.close(reason: "test")
        XCTAssertEqual(closed.count, 1, "events: \(events)")
        // Speech + 3 s of filled silence + speech (closed right away, so no trailing second).
        XCTAssertEqual(closed[0].speechEnd, 2 * duration(s) + 3, accuracy: 0.5)
    }

    func testMaximumLengthStartsANewConversation() async throws {
        let l = try await listener(quiet: 30) { $0.maxSeconds = 4 }
        let s = try speech()
        try await feed(l, s + s + s, from: t0)
        XCTAssertGreaterThanOrEqual(closed.count, 1, "events: \(events)")
        XCTAssertGreaterThanOrEqual(opened.count, 2)
        XCTAssertTrue(log.contains("closed (reached the maximum length)"), log)
        for e in closed { XCTAssertLessThanOrEqual(e.speechEnd, 4.3) }
    }

    /// "Delete the last N minutes" with a conversation open since before the cut: it's closed there, its audio
    /// cut there, and queued audio from before now can't open a new one.
    func testForgetCutsTheOpenConversation() async throws {
        let l = try await listener(quiet: 10)
        let s = try speech()
        try await feed(l, s, from: t0)
        let started = try XCTUnwrap(opened.first)
        try await l.forget(from: started.addingTimeInterval(2))
        let e = try XCTUnwrap(closed.first, "events: \(events)")
        XCTAssertEqual(e.speechEnd, 2, accuracy: 0.001)
        XCTAssertLessThanOrEqual(e.speechSeconds, 2)
        XCTAssertEqual(WavFile.duration(of: spool.wav(e.id)), 2, accuracy: 0.001)
        XCTAssertEqual(spool.load(e.id)?.speechEnd ?? 0, 2, accuracy: 0.001)
        XCTAssertNil(l.conversationStartedAt)
        XCTAssertTrue(log.contains("closed (deleted the last minutes)"), log)
    }

    /// The open conversation started after the cut: it's gone, audio and all.
    func testForgetDropsAConversationThatStartedAfterTheCut() async throws {
        let l = try await listener(quiet: 10)
        try await feed(l, try speech(), from: t0)
        let id = try XCTUnwrap(spool.openID)
        try await l.forget(from: t0.addingTimeInterval(-60))
        XCTAssertEqual(closed.count, 0)
        XCTAssertEqual(discarded, [id])
        XCTAssertFalse(FileManager.default.fileExists(atPath: spool.wav(id).path))
        XCTAssertNil(spool.load(id))
        XCTAssertNil(spool.openID)
    }

    /// Pause or sleep: reset closes what's open and forgets time continuity (no gap close later).
    func testResetClosesAndForgets() async throws {
        let l = try await listener(quiet: 10)
        let s = try speech()
        try await feed(l, s, from: t0)
        await l.reset()
        XCTAssertEqual(closed.count, 1, "events: \(events)")
        XCTAssertTrue(log.contains("closed (reset)"), log)
        try await feed(l, silence(2), from: t0.addingTimeInterval(3600))
        XCTAssertFalse(log.contains("gap in audio"), log)
        XCTAssertEqual(closed.count, 1)
    }
}
