import XCTest

@testable import LiveCore

/// When this Mac's audio is tapped, and how its live track shares the one engine with the mic. No Core Audio:
/// nothing here creates a tap.
final class MacAudioLiveTests: XCTestCase {
    typealias Want = MacAudio.Want

    let on = Want(switchOn: true, listening: true, playing: true, supported: true)

    // MARK: when to tap

    func testTapsOnlyWhenEverythingSaysSo() {
        XCTAssertTrue(MacAudio.shouldTap(on))
        var w = on
        w.switchOn = false
        XCTAssertFalse(MacAudio.shouldTap(w), "the switch is off")
        w = on
        w.playing = false
        XCTAssertFalse(MacAudio.shouldTap(w), "nothing is playing: no tap, no cost")
        w = on
        w.listening = false
        XCTAssertFalse(MacAudio.shouldTap(w), "always-on is off or listening hasn't begun")
        w = on
        w.paused = true
        XCTAssertFalse(MacAudio.shouldTap(w), "paused")
        w = on
        w.asleep = true
        XCTAssertFalse(MacAudio.shouldTap(w), "asleep")
        w = on
        w.supported = false
        XCTAssertFalse(MacAudio.shouldTap(w), "older than macOS 14.2")
    }

    func testOpensOnceSomethingHasPlayedForAMoment() {
        var l = MacAudio.Lifecycle()
        XCTAssertNil(l.update(on, now: 10))
        XCTAssertEqual(l.next(now: 10), MacAudio.Lifecycle.openAfter)
        XCTAssertNil(l.update(on, now: 10.3))
        XCTAssertEqual(l.update(on, now: 10.5), .open)
        XCTAssertTrue(l.open)
        XCTAssertNil(l.next(now: 10.5))
    }

    func testAClickOrANotificationSoundNeverOpensIt() {
        var l = MacAudio.Lifecycle()
        var quiet = on
        quiet.playing = false
        XCTAssertNil(l.update(on, now: 0))
        XCTAssertNil(l.update(quiet, now: 0.2))
        XCTAssertNil(l.update(quiet, now: 5))
        XCTAssertFalse(l.open)
        XCTAssertNil(l.next(now: 5))
    }

    func testAPausedVideoKeepsItForAWhile() {
        var l = MacAudio.Lifecycle()
        _ = l.update(on, now: 0)
        XCTAssertEqual(l.update(on, now: 1), .open)
        var quiet = on
        quiet.playing = false
        XCTAssertNil(l.update(quiet, now: 2))
        XCTAssertNil(l.update(quiet, now: 10), "paused for 8 s: still open")
        XCTAssertNil(l.update(on, now: 12), "playing again: nothing to do")
        XCTAssertNil(l.update(quiet, now: 13))
        XCTAssertEqual(l.update(quiet, now: 13 + MacAudio.Lifecycle.closeAfter), .close)
        XCTAssertFalse(l.open)
    }

    func testTurnedOffPausedOrAsleepClosesAtOnce() {
        for change in [\Want.switchOn, \Want.listening, \Want.supported] {
            var l = MacAudio.Lifecycle()
            _ = l.update(on, now: 0)
            XCTAssertEqual(l.update(on, now: 1), .open)
            var w = on
            w[keyPath: change] = false
            XCTAssertEqual(l.update(w, now: 1.1), .close)
        }
        for change in [\Want.paused, \Want.asleep] {
            var l = MacAudio.Lifecycle()
            _ = l.update(on, now: 0)
            XCTAssertEqual(l.update(on, now: 1), .open)
            var w = on
            w[keyPath: change] = true
            XCTAssertEqual(l.update(w, now: 1.1), .close)
        }
    }

    // MARK: apps that hold an output open, playing nothing

    typealias Quiet = MacAudio.Quiet
    let never = -Double.infinity

    func testALongSilenceClosesItTillAnotherAppPlays() {
        var q = Quiet(now: 0)
        XCTAssertNil(q.update(playing: [7], lastSound: never, now: 10))
        XCTAssertNil(q.update(playing: [7], lastSound: never, now: Quiet.closeAfter - 0.1))
        XCTAssertEqual(q.update(playing: [7], lastSound: never, now: Quiet.closeAfter), .close)
        XCTAssertEqual(q.holders, [7])
        XCTAssertNil(q.update(playing: [7], lastSound: never, now: Quiet.closeAfter + 1), "the same app holding it")
        XCTAssertEqual(q.update(playing: [7, 9], lastSound: never, now: Quiet.closeAfter + 2), .open, "another app started")
        XCTAssertFalse(q.peeking)
    }

    func testSoundKeepsItOpen() {
        var q = Quiet(now: 0)
        XCTAssertNil(q.update(playing: [7], lastSound: 30, now: Quiet.closeAfter))
        XCTAssertNil(q.update(playing: [7], lastSound: 30, now: 30 + Quiet.closeAfter - 0.1))
        XCTAssertEqual(q.update(playing: [7], lastSound: 30, now: 30 + Quiet.closeAfter), .close)
    }

    func testAnAppThatStopsAndPlaysAgainOpensIt() {
        var q = Quiet(now: 0)
        XCTAssertEqual(q.update(playing: [7, 9], lastSound: never, now: Quiet.closeAfter), .close)
        XCTAssertNil(q.update(playing: [9], lastSound: never, now: 50), "7 stopped")
        XCTAssertEqual(q.update(playing: [7, 9], lastSound: never, now: 51), .open, "7 plays again")
    }

    /// One of them may start making sound with nothing in Core Audio changing (someone talks on a call): it looks
    /// for a moment now and then, and stays open once it hears something.
    func testItLooksNowAndThen() {
        var q = Quiet(now: 0)
        let closed = Quiet.closeAfter
        XCTAssertEqual(q.update(playing: [7], lastSound: never, now: closed), .close)
        XCTAssertNil(q.update(playing: [7], lastSound: never, now: closed + Quiet.peekEvery - 0.1))
        XCTAssertEqual(q.update(playing: [7], lastSound: never, now: closed + Quiet.peekEvery), .open)
        XCTAssertTrue(q.peeking)
        let peek = closed + Quiet.peekEvery
        XCTAssertEqual(q.update(playing: [7], lastSound: never, now: peek + Quiet.peekFor), .close, "still nothing")
        XCTAssertEqual(q.update(playing: [7], lastSound: never, now: peek + Quiet.peekFor + Quiet.peekEvery), .open)
        let next = peek + Quiet.peekFor + Quiet.peekEvery
        XCTAssertNil(q.update(playing: [7], lastSound: next + 0.3, now: next + Quiet.peekFor), "heard something")
        XCTAssertFalse(q.peeking)
        XCTAssertNil(q.update(playing: [7], lastSound: next + 0.3, now: next + 30))
        XCTAssertEqual(q.update(playing: [7], lastSound: next + 0.3, now: next + 0.3 + Quiet.closeAfter), .close)
    }

    func testNoLooksWithNothingPlaying() {
        var q = Quiet(now: 0)
        XCTAssertEqual(q.update(playing: [7], lastSound: never, now: Quiet.closeAfter), .close)
        XCTAssertNil(q.update(playing: [], lastSound: never, now: Quiet.closeAfter + 60))
    }

    // MARK: one engine, two tracks

    func testTheMicAloneNeverWaits() {
        var t = SharedEngine.Turns()
        for i in 0..<5 {
            XCTAssertEqual(t.request(.mic, now: Double(i)), .same)
            t.done(.mic, now: Double(i) + 0.01)
        }
    }

    func testTheOtherTrackGetsItWhenTheHolderGoesQuiet() {
        var t = SharedEngine.Turns()
        XCTAssertEqual(t.request(.mic, now: 0), .same)
        XCTAssertNil(t.request(.mac, now: 0.01), "the mic is feeding")
        t.done(.mic, now: 0.02)
        XCTAssertNil(t.request(.mac, now: 0.1), "the mic may carry on")
        XCTAssertEqual(t.request(.mic, now: 0.12), .same)
        t.done(.mic, now: 0.13)
        XCTAssertEqual(t.request(.mac, now: 0.14 + SharedEngine.Turns.idleSwitch), .switched, "the mic went quiet")
        XCTAssertNil(t.request(.mic, now: 0.6), "now the Mac's")
    }

    func testBothTalkingSwitchesAfterTheLongestWait() {
        var t = SharedEngine.Turns()
        var now = 0.0
        XCTAssertEqual(t.request(.mic, now: now), .same)
        XCTAssertNil(t.request(.mac, now: now))
        var switched = false
        while now < 10, !switched {
            t.done(.mic, now: now + 0.01)
            now += 0.05
            if t.request(.mac, now: now) == .switched {
                switched = true
                break
            }
            XCTAssertEqual(t.request(.mic, now: now), .same)
        }
        XCTAssertTrue(switched)
        XCTAssertEqual(now, SharedEngine.Turns.maxWait, accuracy: 0.06)
        XCTAssertEqual(t.holder, .mac)
    }

    func testALeftTrackGivesItUpAtOnce() {
        var t = SharedEngine.Turns()
        XCTAssertEqual(t.request(.mac, now: 0), .same)
        t.done(.mac, now: 0.01)
        t.leave(.mac)
        XCTAssertEqual(t.request(.mic, now: 0.02), .same)
    }

    /// The engine hears one stream; each track gets its own words back on its own clock, and a switch starts a
    /// fresh stream (the last one finished first).
    func testWordsGoBackToTheirTrackOnTheirOwnClock() async throws {
        let fake = FakeEngine()
        let shared = SharedEngine(fake)
        let mic = shared.track(.mic), mac = shared.track(.mac)
        let micWords = Collected(), macWords = Collected()
        try await mic.start { u in micWords.add(u.tokens) }
        try await mac.start { u in macWords.add(u.tokens) }
        let second = [Float](repeating: 0, count: 16_000)
        try await mic.feed(second)  // mic 0-1 s
        try await mic.feed(second)  // mic 1-2 s
        try await Task.sleep(nanoseconds: UInt64(SharedEngine.Turns.idleSwitch * 1.2e9))
        try await mac.feed(second)  // the Mac's 0-1 s, after the mic went quiet
        try await Task.sleep(nanoseconds: UInt64(SharedEngine.Turns.idleSwitch * 1.2e9))
        try await mic.feed(second)  // mic 2-3 s
        await mac.stop()
        await mic.stop()
        // The fake says one word at the start of each block it's fed, timed on the stream it heard.
        XCTAssertEqual(micWords.starts, [0, 1, 2])
        XCTAssertEqual(macWords.starts, [0])
        XCTAssertEqual(fake.starts, 3, "the mic's start, then a fresh stream at each switch")
        XCTAssertEqual(fake.stops, 3)
    }

    /// The Mac's audio stopped and came back at once: the new session started before the old one had stopped.
    /// The old one's late audio and its stop leave the new one alone.
    func testAQuickRestartKeepsTheNewMacSession() async throws {
        let fake = FakeEngine()
        let shared = SharedEngine(fake)
        let mic = shared.track(.mic), old = shared.track(.mac), new = shared.track(.mac)
        let oldWords = Collected(), newWords = Collected()
        try await mic.start { _ in }
        try await old.start { u in oldWords.add(u.tokens) }
        try await new.start { u in newWords.add(u.tokens) }
        let second = [Float](repeating: 0, count: 16_000)
        try await old.feed(second)  // still batched when it was told to stop
        await old.stop()
        try await new.feed(second)
        try await new.feed(second)
        await new.stop()
        await mic.stop()
        XCTAssertEqual(newWords.starts, [0, 1], "on the new session's own clock")
        XCTAssertEqual(oldWords.starts, [])
        XCTAssertEqual(fake.fed, 32_000, "the old session's late audio never reached the engine")
    }

    /// After a dictation the Mac's backlog goes in a second at a time, so the next dictation gets the engine after a
    /// piece of it, not all of it (43 s of it in one go kept that dictation's words out of the pill): the mic's word
    /// comes before the rest of the Mac's, and the Mac's words keep their own clock across the switches.
    func testADictationCutsIntoTheOtherTracksBacklog() async throws {
        let fake = FakeEngine(delay: 0.03)
        let shared = SharedEngine(fake)
        let mic = shared.track(.mic), mac = shared.track(.mac)
        let words = Tagged()
        try await mic.start { u in words.add("mic", u.tokens) }
        try await mac.start { u in words.add("mac", u.tokens) }
        let backlog = Task { try await mac.feed([Float](repeating: 0, count: 5 * 16_000)) }
        try await Task.sleep(nanoseconds: 45_000_000)  // into its second piece
        mic.prioritize(true)
        try await mic.feed([Float](repeating: 0, count: 1_600))
        mic.prioritize(false)
        try await backlog.value
        await mac.stop()
        await mic.stop()
        let order = words.tags
        let micAt = try XCTUnwrap(order.firstIndex(of: "mic"))
        XCTAssertLessThan(micAt, order.lastIndex(of: "mac") ?? -1, "the mic got in before the rest of the backlog")
        XCTAssertEqual(words.starts("mac"), [0, 1, 2, 3, 4])
        XCTAssertEqual(words.starts("mic"), [0])
    }

    func testTheMacsAudioIsDroppedWhileTheEngineIsStopped() async throws {
        let fake = FakeEngine()
        let shared = SharedEngine(fake)
        let mac = shared.track(.mac)
        let words = Collected()
        try await mac.start { u in words.add(u.tokens) }
        try await mac.feed([Float](repeating: 0, count: 1_600))
        XCTAssertEqual(fake.fed, 0, "the mic's session hasn't started the engine")
        XCTAssertEqual(words.starts, [])
    }

    // MARK: Now's lines

    func testNowMergesTheTwoTracksByTime() {
        func line(_ id: Int, _ start: Double, slot: Int?) -> LiveLine {
            LiveLine(id: id, speaker: slot, settled: true, text: "\(id)", start: start, end: start + 1)
        }
        let mic = [line(0, 0, slot: 0), line(5, 6, slot: 1), line(9, 20, slot: 0)]
        let mac = [line(LiveLine.macIDs, 3, slot: LiveLine.macSlot), line(LiveLine.macIDs + 4, 6, slot: LiveLine.macSlot)]
        let merged = LiveMerge.lines(mic: mic, mac: mac)
        XCTAssertEqual(merged.map(\.id), [0, LiveLine.macIDs, 5, LiveLine.macIDs + 4, 9], "a tie goes to the mic")
        XCTAssertEqual(Set(merged.map(\.id)).count, merged.count, "ids never clash across tracks")
        XCTAssertEqual(LiveMerge.lines(mic: mic, mac: []).map(\.id), mic.map(\.id))
        XCTAssertEqual(LiveMerge.lines(mic: [], mac: mac).map(\.id), mac.map(\.id))
    }

    func testHiddenEchoWordsLeaveTheirLine() {
        let t = LiveTranscript()
        t.add([LiveToken(text: " hello", start: 0), LiveToken(text: " welcome", start: 0.3), LiveToken(text: " there", start: 0.5)])
        XCTAssertEqual(t.lines(hiding: [1]).map(\.text), ["hello there"])
        XCTAssertEqual(t.lines().map(\.text), ["hello welcome there"])
    }
}

/// Collects tokens from a callback on any thread.
private final class Collected: @unchecked Sendable {
    private let lock = NSLock()
    private var tokens: [LiveToken] = []
    func add(_ more: [LiveToken]) { lock.withLock { tokens += more } }
    var starts: [Double] { lock.withLock { tokens.map(\.start) } }
}

/// Collects tokens from several tracks in the order they came, from a callback on any thread.
private final class Tagged: @unchecked Sendable {
    private let lock = NSLock()
    private var all: [(tag: String, start: Double)] = []
    func add(_ tag: String, _ more: [LiveToken]) { lock.withLock { all += more.map { (tag, $0.start) } } }
    var tags: [String] { lock.withLock { all.map(\.tag) } }
    func starts(_ tag: String) -> [Double] { lock.withLock { all.filter { $0.tag == tag }.map(\.start) } }
}

/// Says one word at the start of each block it's fed, timed on the one stream it hears since its last start.
private final class FakeEngine: LiveEngine, @unchecked Sendable {
    let name = "fake"
    let modelDelay = "0"
    let lookaheadSeconds = 0.0
    private let lock = NSLock()
    private var onUpdate: (@Sendable (LiveUpdate) -> Void)?
    private var position = 0
    private var _starts = 0, _stops = 0, _fed = 0
    /// How long each feed takes.
    private let delay: Double
    var starts: Int { lock.withLock { _starts } }
    var stops: Int { lock.withLock { _stops } }
    var fed: Int { lock.withLock { _fed } }

    init(delay: Double = 0) { self.delay = delay }

    func prepare(progress: @escaping @Sendable (Double, String) -> Void) async throws {}

    func start(onUpdate: @escaping @Sendable (LiveUpdate) -> Void) async throws {
        lock.withLock {
            self.onUpdate = onUpdate
            position = 0
            _starts += 1
        }
    }

    func feed(_ samples: [Float]) async throws {
        if delay > 0 { try await Task.sleep(nanoseconds: UInt64(delay * 1e9)) }
        let (update, at) = lock.withLock { () -> ((@Sendable (LiveUpdate) -> Void)?, Int) in
            defer {
                position += samples.count
                _fed += samples.count
            }
            return (onUpdate, position)
        }
        update?(LiveUpdate(tokens: [LiveToken(text: " w", start: Double(at) / AudioClock.sampleRate)]))
    }

    func stop() async {
        lock.withLock {
            onUpdate = nil
            _stops += 1
        }
    }
}
