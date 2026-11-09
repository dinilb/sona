import AVFoundation
import XCTest

@testable import LiveCore

/// How often audio moves down the live path: sources hand it over every 10 ms only while something waits on it,
/// and the session wakes the engine and the diarizer only when they can do something with it. No models.
final class PaceTests: XCTestCase {
    // MARK: when a model can step

    func testEngineStepsAfterChunkPlusRightContextThenEveryChunk() {
        // Parakeet Unified 320 ms: 2560-sample chunks, 2560 samples of right context.
        XCTAssertEqual(samplesUntilStep(fed: 0, first: 5_120, step: 2_560), 5_120)
        XCTAssertEqual(samplesUntilStep(fed: 5_119, first: 5_120, step: 2_560), 1)
        XCTAssertEqual(samplesUntilStep(fed: 5_120, first: 5_120, step: 2_560), 2_560)
        XCTAssertEqual(samplesUntilStep(fed: 6_000, first: 5_120, step: 2_560), 1_680)
        XCTAssertEqual(samplesUntilStep(fed: 7_680, first: 5_120, step: 2_560), 2_560)
        XCTAssertEqual(samplesUntilStep(fed: 123, first: 0, step: 0), 0, "no step size: any sample might")
    }

    func testDiarizerStepsWhenItsMelFramesAreIn() {
        // Nemotron 3 `fast`: 72 mel frames a chunk plus 32 of right context, 10 ms hop, 512-sample window.
        let first = LiveDiarizer.samplesUntilStep(fed: 0, core: 72, right: 32)
        XCTAssertEqual(first, 16_736, "about 1.04 s, the latency it's published with")
        XCTAssertEqual(LiveDiarizer.samplesUntilStep(fed: first - 1, core: 72, right: 32), 1)
        XCTAssertEqual(LiveDiarizer.samplesUntilStep(fed: first, core: 72, right: 32), 11_520, "then every 0.72 s")
        XCTAssertEqual(LiveDiarizer.samplesUntilStep(fed: first + 11_520, core: 72, right: 32), 11_520)
    }

    // MARK: the session

    /// Ungated (no VAD here): the engine only gets audio once it completes a step, except while a dictation key is
    /// held (every piece at once), and at the end everything left goes in.
    func testTheEngineWaitsForAWholeStepUnlessAKeyIsHeld() async throws {
        let engine = SteppingEngine()
        let relay = RelaySource()
        let paces = Recorded<Bool>()
        relay.paced(by: { paces.add($0) })
        let session = LiveSession(engine: engine, source: relay)
        session.voiceGate = false
        let run = Task { try await session.run { _ in } }
        var pushed = 0
        func push(_ n: Int) async throws {
            relay.push([Float](repeating: 0.1, count: n), hostTime: hostNow())
            pushed += n
            try await waitUntil { session.audioSeconds >= Double(pushed) / AudioClock.sampleRate - 1e-9 }
            try await Task.sleep(nanoseconds: 30_000_000)  // the engine's loop gets a moment either way
        }

        try await push(160)
        XCTAssertEqual(engine.feeds, [], "10 ms can't complete the first step (5120 samples)")
        session.holdOpen(true)
        try await push(160)
        XCTAssertEqual(engine.feeds, [320], "a held key gets every piece at once")
        session.holdOpen(false)
        for _ in 0..<29 { try await push(160) }
        XCTAssertEqual(engine.feeds, [320], "4640 of the 4800 the first step still needs")
        try await push(160)
        XCTAssertEqual(engine.feeds, [320, 4_800])
        try await push(1_000)
        XCTAssertEqual(engine.feeds, [320, 4_800], "the next step needs 2560")
        relay.stop()
        try await run.value
        XCTAssertEqual(engine.feeds, [320, 4_800, 1_000], "the rest goes in at the end")
        XCTAssertEqual(paces.all.last, true, "no gate: the source is asked for every 10 ms")
    }

    // MARK: a file standing in for the mic

    func testAFileComesInBatchesUntilSomethingWaitsOnIt() async throws {
        let url = try wav(seconds: 0.3)
        let calm = try FileSource(url: url)
        calm.setUrgent(false)
        try calm.start()
        var sizes: [Int] = []
        for await piece in calm.chunks { sizes.append(piece.count) }
        XCTAssertEqual(sizes, Array(repeating: 800, count: 6), "50 ms at a time")

        let urgent = try FileSource(url: url)
        try urgent.start()
        sizes = []
        for await piece in urgent.chunks { sizes.append(piece.count) }
        XCTAssertEqual(sizes, Array(repeating: 160, count: 30), "10 ms at a time, as before pacing")
    }

    func testTurningUrgentWakesACalmFileAtOnce() async throws {
        let url = try wav(seconds: 1)
        let source = try FileSource(url: url)
        source.setUrgent(false)
        try source.start()
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.32) { source.setUrgent(true) }
        var sizes: [Int] = []
        for await piece in source.chunks { sizes.append(piece.count) }
        XCTAssertEqual(sizes.reduce(0, +), 16_000)
        XCTAssertTrue(sizes.allSatisfy { $0 % 160 == 0 }, "\(sizes)")
        let firstSmall = try XCTUnwrap(sizes.firstIndex { $0 < 800 }, "\(sizes)")
        XCTAssertTrue(sizes[..<firstSmall].allSatisfy { $0 == 800 })
        XCTAssertTrue(sizes[(firstSmall + 1)...].allSatisfy { $0 == 160 }, "\(sizes)")
    }

    // MARK: helpers

    private func wav(seconds: Double) throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("sona-pace-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("clip.wav")
        do {
            let file = try AVAudioFile(
                forWriting: url, settings: PCM.format16k.settings, commonFormat: .pcmFormatFloat32, interleaved: false)
            try file.write(from: PCM.buffer([Float](repeating: 0.1, count: Int(seconds * AudioClock.sampleRate))))
        }
        return url
    }

    private func waitUntil(_ done: () -> Bool) async throws {
        let deadline = hostNow() + 2
        while !done() {
            guard hostNow() < deadline else { return XCTFail("timed out") }
            try await Task.sleep(nanoseconds: 2_000_000)
        }
    }
}

/// Records the size of each feed, and steps like Parakeet Unified 320 ms.
private final class SteppingEngine: LiveEngine, @unchecked Sendable {
    let name = "stepping"
    let modelDelay = "0"
    let lookaheadSeconds = 0.32
    private let lock = NSLock()
    private var _feeds: [Int] = []
    var feeds: [Int] { lock.withLock { _feeds } }

    func prepare(progress: @escaping @Sendable (Double, String) -> Void) async throws {}
    func start(onUpdate: @escaping @Sendable (LiveUpdate) -> Void) async throws {}
    func feed(_ samples: [Float]) async throws { lock.withLock { _feeds.append(samples.count) } }
    func stop() async {}
    func samplesUntilStep(fed: Int) -> Int { LiveCore.samplesUntilStep(fed: fed, first: 5_120, step: 2_560) }
}

private final class Recorded<T: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var items: [T] = []
    func add(_ x: T) { lock.withLock { items.append(x) } }
    var all: [T] { lock.withLock { items } }
}
