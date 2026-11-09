import Foundation

/// Pipes an audio source into an engine until the source ends or `cancel()` is called.
// @unchecked: mutable state is behind `lock`; `voiceGate` and `gateConfig` are set before `run` only.
public final class LiveSession: @unchecked Sendable {
    public let engine: LiveEngine
    public let source: LiveAudioSource
    private let lock = NSLock()
    private var _computeSeconds = 0.0
    private var _audioSeconds = 0.0
    private var _slowestFeedMs = 0.0
    /// Audio that arrived while the engine was busy. Fed as one block next time, so a slow step
    /// never builds a queue of tiny calls (and nothing is dropped, which would break the clock).
    private var pending: [Float] = []
    /// Optional speaker separation. Runs on its own task with its own backlog, so a slow diarizer
    /// step never holds up words.
    public let diarizer: LiveDiarizer?
    private var diarPending: [Float] = []
    private var diarFailed = false
    /// Only feed the engine and diarizer while someone is talking (Silero VAD). Set before `run`.
    public var voiceGate = false
    public var gateConfig = VoiceGate.Config()
    /// Fed time to session time, and the diarizer's frames placed in session time (gate on only).
    private var timeMap = TimeMap()
    /// The engine's own fed-to-session map: like `timeMap`, plus any silence `flush` gave only the engine.
    private var asrMap = TimeMap()
    /// Wakes the engine loop (set while `run` is going), so `flush` can push silence through right away.
    private var engineWaker: AsyncStream<Void>.Continuation?
    private var frameMapper = SpeakerFrameMapper()
    private var _gateActive = false
    /// Samples the engine has finished a `feed` call on, and whether the gate is letting audio through.
    private var _engineFed = 0
    private var _gateOpen = true
    private var _holdOpen = false
    /// Session sample up to which the gate has made its decisions.
    private var _gateDecided = 0
    private var _fedSeconds = 0.0
    private var _vadSeconds = 0.0
    private var _diarSeconds = 0.0
    /// Samples handed to the engine since it started (in flight too), and how many more it needs before its
    /// next step can produce words: until then, audio waits in `pending`.
    private var _engineTaken = 0
    private var _engineNeed = 0
    /// Feed whatever is pending at the next wake, step or not: a flush, the gate closing, the end.
    private var _engineNow = false
    private var _diarNeed = 0
    private var _diarNow = false
    /// The pace last asked of the source (nil: not yet).
    private var _urgent: Bool?

    /// Seconds spent inside the engine, to compare with the audio's length.
    public var computeSeconds: Double { lock.withLock { _computeSeconds } }
    /// Session audio received (with the gate on, more than the engine was fed).
    public var audioSeconds: Double { lock.withLock { _audioSeconds } }
    /// Audio the engine and diarizer were fed.
    public var fedSeconds: Double { lock.withLock { _fedSeconds } }
    /// Seconds in the voice detector and in the diarizer (both off the word path).
    public var vadSeconds: Double { lock.withLock { _vadSeconds } }
    public var diarizerSeconds: Double { lock.withLock { _diarSeconds } }
    /// The gate was asked for and its model loaded (if it can't load, the session runs ungated).
    public var gateActive: Bool { lock.withLock { _gateActive } }
    /// Worst time one feed call took, in ms. If this nears the chunk length, the engine is falling behind.
    public var slowestFeedMs: Double { lock.withLock { _slowestFeedMs } }

    public init(engine: LiveEngine, source: LiveAudioSource, diarizer: LiveDiarizer? = nil) {
        self.engine = engine
        self.source = source
        self.diarizer = diarizer
    }

    public func run(onUpdate: @escaping @Sendable (LiveUpdate) -> Void) async throws {
        let diarizer = diarizer
        // Speech only, if asked for. If Silero can't load, words still flow, just ungated.
        let vad = voiceGate ? try? await VoiceGate.loadModel() : nil
        let gate = vad.map { VoiceGate(vad: $0, config: gateConfig) }
        let gated = gate != nil
        let (wake, waker) = AsyncStream.makeStream(of: Void.self, bufferingPolicy: .bufferingNewest(1))
        lock.withLock {
            _gateActive = gated
            timeMap = TimeMap()
            asrMap = TimeMap()
            frameMapper = SpeakerFrameMapper()
            engineWaker = waker
        }
        let (diarWake, diarWaker) = AsyncStream.makeStream(of: Void.self, bufferingPolicy: .bufferingNewest(1))
        var pump: Task<Void, Never>?
        var diarTask: Task<Void, Never>?
        var failure: Error?
        do {
            // Engines and the diarizer count time in the audio they were fed; everything leaving the session
            // is in session time, the clock the latency is measured on.
            let engineUpdate: @Sendable (LiveUpdate) -> Void
            if gated {
                engineUpdate = { [self] update in onUpdate(toSession(update)) }
            } else {
                engineUpdate = onUpdate
            }
            try await engine.start(onUpdate: engineUpdate)
            let engineNeed = engine.samplesUntilStep(fed: 0)
            diarizer?.reset()
            let diarNeed = diarizer?.samplesUntilStep ?? 0
            lock.withLock {
                _engineNeed = engineNeed
                _diarNeed = diarNeed
                // The gate starts closed: until it opens (or a key is held) nothing waits on the audio.
                _gateOpen = !gated
                updatePace()
            }
            try source.start()
            pump = Task { [self] in
                var vadBroken = false
                for await chunk in source.chunks {
                    lock.withLock { _audioSeconds += Double(chunk.count) / AudioClock.sampleRate }
                    guard let gate else {
                        feed(VoiceGate.Piece(start: 0, samples: chunk), mapped: false)
                        release(waker, diarWaker)
                        continue
                    }
                    // The dictation key is down: open now instead of waiting for the VAD (no first-word delay, and
                    // the engine is already warm when the words come).
                    let hold = lock.withLock { _holdOpen }
                    gate.held = hold
                    if hold, let piece = gate.openNow() {
                        feed(piece, mapped: true)
                        release(waker, diarWaker)
                    }
                    // While open, audio goes out before the VAD runs, so the gate adds no delay to words.
                    if let piece = gate.accept(chunk) {
                        feed(piece, mapped: true)
                        release(waker, diarWaker)
                    }
                    guard !vadBroken else { continue }
                    do {
                        if let piece = try await gate.decide() {
                            feed(piece, mapped: true)
                            release(waker, diarWaker)
                        }
                    } catch {
                        // No VAD: stay open for the rest of the session.
                        vadBroken = true
                        if let piece = gate.forceOpen() {
                            feed(piece, mapped: true)
                            release(waker, diarWaker)
                        }
                    }
                    let vadSeconds = gate.vadSeconds, open = gate.isOpen, decided = gate.decided
                    let closed = lock.withLock { () -> Bool in
                        let closed = _gateOpen && !open
                        _vadSeconds = vadSeconds
                        _gateOpen = open
                        _gateDecided = decided
                        updatePace()
                        // The rest (less than a step) goes in now: `hasDecoded` counts on nothing waiting once closed.
                        if closed {
                            _engineNow = true
                            _diarNow = true
                        }
                        return closed
                    }
                    if closed { release(waker, diarWaker) }
                }
                // The end: everything still waiting goes in before the engine and the diarizer finish.
                lock.withLock {
                    _engineNow = true
                    _diarNow = true
                }
                release(waker, diarWaker)
                waker.finish()
                diarWaker.finish()
            }
            diarTask = diarizer.map { diarizer in
                Task.detached(priority: .userInitiated) { [self] in
                    do {
                        wakes: for await _ in diarWake {
                            while true {
                                // Too far behind (see `feed`): words carry on without speakers.
                                if lock.withLock({ diarFailed }) {
                                    onUpdate(LiveUpdate(speakersFailed: true))
                                    break wakes
                                }
                                let block = lock.withLock { () -> [Float] in
                                    guard !diarPending.isEmpty else {
                                        _diarNow = false
                                        return []
                                    }
                                    guard _diarNow || diarPending.count >= _diarNeed else { return [] }
                                    _diarNow = false
                                    defer { diarPending.removeAll(keepingCapacity: true) }
                                    return diarPending
                                }
                                guard !block.isEmpty else { break }
                                let t = hostNow()
                                let frames = try diarizer.feed(block)
                                let took = hostNow() - t
                                let need = diarizer.samplesUntilStep
                                let placed = lock.withLock { () -> [Int8] in
                                    _diarSeconds += took
                                    _diarNeed = need
                                    return gated ? frameMapper.map(frames, with: timeMap) : frames
                                }
                                if !placed.isEmpty { onUpdate(LiveUpdate(speakerFrames: placed)) }
                            }
                        }
                        let tail = try diarizer.finish()
                        let placed = lock.withLock { gated ? frameMapper.map(tail, with: timeMap) : tail }
                        if !placed.isEmpty { onUpdate(LiveUpdate(speakerFrames: placed)) }
                    } catch {
                        // Speakers are a nice-to-have: words keep flowing without them.
                        lock.withLock {
                            diarFailed = true
                            diarPending = []
                        }
                        onUpdate(LiveUpdate(speakersFailed: true))
                    }
                }
            }
            for await _ in wake {
                // Audio that came in during a feed may already complete the next step: feed again before waiting.
                while true {
                    let block = lock.withLock { () -> [Float] in
                        guard !pending.isEmpty else {
                            _engineNow = false
                            return []
                        }
                        guard _engineNow || _holdOpen || pending.count >= _engineNeed else { return [] }
                        _engineNow = false
                        _engineTaken += pending.count
                        defer { pending.removeAll(keepingCapacity: true) }
                        return pending
                    }
                    guard !block.isEmpty else { break }
                    let t = hostNow()
                    try await engine.feed(block)
                    let took = hostNow() - t
                    let need = engine.samplesUntilStep(fed: lock.withLock { _engineTaken })
                    lock.withLock {
                        _computeSeconds += took
                        _slowestFeedMs = max(_slowestFeedMs, took * 1000)
                        _engineFed += block.count
                        _engineNeed = need
                    }
                }
            }
        } catch {
            failure = error
        }
        // Every exit path: stop the audio, and let the diarizer finish before anyone can reuse it.
        lock.withLock { engineWaker = nil }
        source.stop()
        pump?.cancel()
        waker.finish()
        diarWaker.finish()
        await diarTask?.value
        await engine.stop()
        if let failure { throw failure }
    }

    /// Wakes the engine once what's queued can complete one of its steps (or it's wanted now: a key held, a flush,
    /// the gate closing), and the diarizer once it can run a chunk. Waking them for every 10 ms of audio they can do
    /// nothing with costs a model call's bookkeeping 100 times a second. Each checks again itself.
    private func release(_ toEngine: AsyncStream<Void>.Continuation, _ toDiarizer: AsyncStream<Void>.Continuation) {
        let (wakeEngine, wakeDiarizer) = lock.withLock { () -> (Bool, Bool) in
            let e = !pending.isEmpty && (_engineNow || _holdOpen || pending.count >= _engineNeed)
            let d = !diarPending.isEmpty && (_diarNow || diarPending.count >= _diarNeed)
            return (e, d)
        }
        if wakeEngine { toEngine.yield() }
        if wakeDiarizer { toDiarizer.yield() }
    }

    /// Under `lock`: tells the source whether anything waits on its audio (the gate open, so words are being shown;
    /// a dictation key down; no gate at all). Only then does it hand audio over every 10 ms; otherwise in ~50 ms
    /// batches, which wake the whole chain a fifth as often.
    private func updatePace() {
        let urgent = !_gateActive || _gateOpen || _holdOpen
        guard urgent != _urgent else { return }
        _urgent = urgent
        source.setUrgent(urgent)
    }

    /// Queues audio for the engine and the diarizer, noting where it sits in the session.
    private func feed(_ piece: VoiceGate.Piece, mapped: Bool) {
        lock.withLock {
            if mapped {
                timeMap.append(sessionStart: piece.start, count: piece.samples.count)
                asrMap.append(sessionStart: piece.start, count: piece.samples.count)
            }
            _fedSeconds += Double(piece.samples.count) / AudioClock.sampleRate
            pending.append(contentsOf: piece.samples)
            guard diarizer != nil, !diarFailed else { return }
            diarPending.append(contentsOf: piece.samples)
            // 30 s behind real time (a busy Neural Engine): give up on speakers rather than grow forever.
            if diarPending.count > 30 * Int(AudioClock.sampleRate) {
                diarFailed = true
                diarPending = []
            }
        }
    }

    /// Someone just finished dictating. Instead of waiting ~0.3 s for real audio to fill the engine's
    /// look-ahead, give the engine that much silence now so the last words come out at compute speed.
    /// Only the engine gets it (the diarizer's timeline stays real), placed right after the audio already
    /// queued. Only while the gate is open: when it's closed, everything is already decoded.
    public func flush() {
        let woke = lock.withLock { () -> AsyncStream<Void>.Continuation? in
            guard _gateActive, _gateOpen, let engineWaker else { return nil }
            let count = Int((engine.lookaheadSeconds + 0.12) * AudioClock.sampleRate)
            asrMap.append(sessionStart: asrMap.sessionEnd, count: count)
            pending.append(contentsOf: repeatElement(0, count: count))
            _engineNow = true
            return engineWaker
        }
        woke?.yield()
    }

    /// An engine update with its fed-time stamps moved to session time.
    private func toSession(_ update: LiveUpdate) -> LiveUpdate {
        let map = lock.withLock { asrMap }
        var u = update
        u.heard = update.heard.map { map.sessionSeconds(fedSeconds: $0) }
        u.locked = update.locked.map { map.sessionSeconds(fedSeconds: $0) }
        u.tokens = update.tokens.map { LiveToken(text: $0.text, start: map.sessionSeconds(fedSeconds: $0.start)) }
        return u
    }

    /// True once every word spoken up to session time `t` has come out of the engine: it has been fed audio
    /// past `t` plus its look-ahead, or the gate closed and everything it let through has been decoded.
    /// Dictation waits on this instead of a fixed delay.
    public func hasDecoded(through t: Double) -> Bool {
        lock.withLock {
            let fed = Double(_engineFed) / AudioClock.sampleRate
            if decodedSession() >= t { return true }
            // Closed only counts once the gate has judged the audio up to `t` (plus a window, since a short
            // word near the end can still open it): otherwise a quick "yeah" hasn't been let through yet.
            let judged = Double(_gateDecided) / AudioClock.sampleRate >= t + 0.3
            return _gateActive && !_gateOpen && judged && pending.isEmpty && fed >= Double(asrMap.fedCount) / AudioClock.sampleRate - 0.001
        }
    }

    /// Session second up to which the engine has heard enough to have put out every word (for the dictation's log
    /// line: how far behind the release it was).
    public var decodedThrough: Double { lock.withLock { decodedSession() } }

    /// Under `lock`.
    private func decodedSession() -> Double {
        let decoded = max(Double(_engineFed) / AudioClock.sampleRate - engine.lookaheadSeconds, 0)
        return _gateActive ? asrMap.sessionSeconds(fedSeconds: decoded) : decoded
    }

    /// Keep the voice gate open (dictation key down) or let it go back to the VAD. While on, a shared engine also
    /// lets this session feed first, so a dictation never waits behind this Mac's audio.
    /// It also asks the source for audio every 10 ms from now (the mic hands over what it has at once), so a key
    /// going down never waits on a batch.
    public func holdOpen(_ on: Bool) {
        lock.withLock {
            _holdOpen = on
            updatePace()
        }
        engine.prioritize(on)
    }

    public func cancel() { source.stop() }
}
