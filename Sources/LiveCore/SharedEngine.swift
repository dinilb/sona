import Foundation

/// One Parakeet engine heard through two live sessions, the mic and what this Mac plays, so the Mac's track needs
/// no second copy of the model. Each session gets its own `LiveEngine` (`track(_:)`), with its own clock: the
/// engine itself hears one stream, and every word it emits is handed back to the track whose audio it came from.
///
/// The tracks take turns (`Turns`), a stretch of speech at a time: a switch mid-word would garble that word in
/// both. The other track's audio waits meanwhile (its session batches it), then goes through at compute speed.
/// Each turn is a fresh stream (the engine finishes the last one and starts over), so a track's words are never
/// heard against the other's audio. With only the mic (no Mac audio playing), a feed goes straight to the engine.
///
/// The mic's session owns the engine's lifetime: its start resets it, its stop finishes it. The Mac's session only
/// comes and goes. Each start owns its track until its own stop: a session that's still stopping when the next one
/// starts on its track (the Mac's audio stopped and came back) never feeds it, gets its words or clears its handler.
// @unchecked: the routing state (`segments`, `fed`, `handlers`, `owners`, `turns`, `realFed`, `running`) is under `lock`;
// feeds into the engine are one at a time (the turn), so the engine is never fed from two places at once.
public final class SharedEngine: @unchecked Sendable {
    public enum Track: Int, Sendable, CaseIterable {
        case mic, mac
    }

    let engine: LiveEngine
    private let lock = NSLock()
    private var turns = Turns()
    private var handlers: [Track: @Sendable (LiveUpdate) -> Void] = [:]
    /// The start that owns each track (from `lastOwner`), until its stop.
    private var owners: [Track: Int] = [:]
    private var lastOwner = 0
    /// Samples each track has fed (its own clock), and the engine since its stream last started.
    private var fed: [Track: Int] = [:]
    private var realFed = 0
    /// Where each stretch of the engine's stream came from, oldest first (pruned as it falls far behind).
    private var segments: [Segment] = []
    /// The mic's session has started the engine and not stopped it.
    private var running = false

    struct Segment {
        var real: Int
        var track: Track
        /// The start whose audio this was: its words go nowhere once another start owns the track.
        var owner = 0
        var trackStart: Int
    }

    public init(_ engine: LiveEngine) { self.engine = engine }

    public func track(_ track: Track) -> LiveEngine { Facade(shared: self, track: track) }

    // MARK: for the facades

    /// Returns this start's token, for its feeds and its stop.
    func start(_ track: Track, onUpdate: @escaping @Sendable (LiveUpdate) -> Void) async throws -> Int {
        let owner = lock.withLock { () -> Int in
            lastOwner += 1
            // One still stopping on this track is done with it.
            if owners[track] != nil { turns.leave(track) }
            owners[track] = lastOwner
            handlers[track] = onUpdate
            fed[track] = 0
            return lastOwner
        }
        guard track == .mic else { return owner }
        // Never while the Mac's track is feeding it.
        await claim()
        defer { lock.withLock { turns.release() } }
        lock.withLock {
            segments = []
            realFed = 0
        }
        try await engine.start { [weak self] update in self?.route(update) }
        lock.withLock { running = true }
        return owner
    }

    /// Ends `owner`'s start. A stop that comes after the next start on its track leaves that one alone.
    func stop(_ track: Track, owner: Int) async {
        guard lock.withLock({ owners[track] == owner }) else { return }
        if track == .mic {
            lock.withLock { running = false }
            await claim()
            await engine.stop()
            lock.withLock { turns.release() }
        }
        lock.withLock {
            guard owners[track] == owner else { return }
            owners[track] = nil
            handlers[track] = nil
            turns.leave(track)
        }
    }

    /// Waits until no feed is running, and keeps others out until `turns.release()`.
    private func claim() async {
        while !lock.withLock({ turns.claim() }) { try? await Task.sleep(nanoseconds: 10_000_000) }
    }

    /// The most that goes into the engine in one go. A track's backlog (the Mac's waits through a whole dictation)
    /// goes in this much at a time, asking for the turn before each piece, so a dictation that starts meanwhile waits
    /// for one piece of it, not all of it: 43 s of the Mac's at once kept the next dictation's words out of its pill.
    static let maxPiece = Int(AudioClock.sampleRate)

    func feed(_ track: Track, owner: Int, _ samples: [Float]) async throws {
        guard samples.count > Self.maxPiece else { return try await feedPiece(track, owner: owner, samples) }
        var from = 0
        while from < samples.count {
            let to = min(from + Self.maxPiece, samples.count)
            try await feedPiece(track, owner: owner, Array(samples[from..<to]))
            from = to
        }
    }

    private func feedPiece(_ track: Track, owner: Int, _ samples: [Float]) async throws {
        // Wait for the turn. Only with both tracks talking at once does this ever sleep.
        var switched = false
        while true {
            let now = hostNow()
            let granted = lock.withLock { () -> Turns.Grant? in
                // Not running, or a newer start owns this track: drop it.
                guard running, owners[track] == owner else { return .skip }
                return turns.request(track, now: now)
            }
            if let granted {
                if granted == .skip { return }
                switched = granted == .switched
                break
            }
            try await Task.sleep(nanoseconds: 40_000_000)
        }
        defer { lock.withLock { turns.done(track, now: hostNow()) } }
        if switched {
            // A fresh stream for this turn: the other track's last words come out first (still routed to it), then
            // the engine starts over, so this track's words are never heard against the other's audio (that lost
            // the first second of a turn).
            await engine.stop()
            try await engine.start { [weak self] update in self?.route(update) }
            lock.withLock {
                segments = []
                realFed = 0
            }
        }
        let current = lock.withLock { () -> Bool in
            guard owners[track] == owner else { return false }
            addSegment(track, owner: owner, count: samples.count, trackStart: fed[track] ?? 0)
            fed[track, default: 0] += samples.count
            return true
        }
        guard current else { return }
        try await engine.feed(samples)
    }

    /// Under `lock`.
    private func addSegment(_ track: Track, owner: Int, count: Int, trackStart: Int) {
        if let last = segments.last, last.track == track, last.owner == owner, last.trackStart + (realFed - last.real) == trackStart {
            // Carries straight on.
        } else {
            segments.append(Segment(real: realFed, track: track, owner: owner, trackStart: trackStart))
        }
        realFed += count
        // Words come out within a second of their audio; keep a minute.
        if segments.count > 64, let first = segments.dropFirst().first, realFed - first.real > 60 * Int(AudioClock.sampleRate) {
            segments.removeFirst()
        }
    }

    /// An engine update, split by track and moved to each track's own clock.
    private func route(_ update: LiveUpdate) {
        let (byTrack, handlers) = lock.withLock { () -> ([Track: LiveUpdate], [Track: @Sendable (LiveUpdate) -> Void]) in
            var out: [Track: LiveUpdate] = [:]
            /// Nil: from a start that no longer owns its track.
            func place(_ seconds: Double) -> (Track, Double)? {
                let real = Int(seconds * AudioClock.sampleRate)
                let s =
                    SharedEngine.segment(containing: real, in: segments)
                    ?? Segment(real: 0, track: .mic, owner: owners[.mic] ?? 0, trackStart: 0)
                guard owners[s.track] == s.owner else { return nil }
                return (s.track, seconds - Double(s.real - s.trackStart) / AudioClock.sampleRate)
            }
            for token in update.tokens {
                guard let at = place(token.start) else { continue }
                out[at.0, default: LiveUpdate()].tokens.append(LiveToken(text: token.text, start: at.1))
            }
            for h in update.heard {
                guard let at = place(h) else { continue }
                out[at.0, default: LiveUpdate()].heard.append(at.1)
            }
            for l in update.locked {
                guard let at = place(l) else { continue }
                out[at.0, default: LiveUpdate()].locked.append(at.1)
            }
            for (track, var u) in out {
                u.appendFinal = u.tokens.map(\.text).joined()
                out[track] = u
            }
            return (out, self.handlers)
        }
        for (track, u) in byTrack { handlers[track]?(u) }
    }

    /// The last segment starting at or before `real`.
    static func segment(containing real: Int, in segments: [Segment]) -> Segment? {
        var lo = 0, hi = segments.count - 1, found: Segment?
        while lo <= hi {
            let mid = (lo + hi) / 2
            if segments[mid].real <= real {
                found = segments[mid]
                lo = mid + 1
            } else {
                hi = mid - 1
            }
        }
        return found ?? segments.first
    }

    /// Someone is dictating on `track` (nil: nobody): it gets the engine at its next feed, and the other track
    /// waits (its session keeps its audio) until this is cleared.
    public func prioritize(_ track: Track?) {
        lock.withLock { turns.priority = track }
    }

    /// When `track`'s next feed can produce words: the engine's own stream carries on if the track has the turn
    /// (or nobody does), and starts over if the other track has it. A guess off by a feed only wakes the session
    /// once more or less; it checks again after every feed.
    func samplesUntilStep(_ track: Track) -> Int {
        let fed = lock.withLock { turns.holder == nil || turns.holder == track ? realFed : 0 }
        return engine.samplesUntilStep(fed: fed)
    }

    /// Whose turn it is to feed the engine. Pure, so it's tested without models.
    /// A track keeps the turn while it keeps feeding; the other gets it once the holder has been quiet for
    /// `idleSwitch` (its gate closed), or has waited `maxWait` (both talking at once). A `priority` track (dictation)
    /// gets it at once, and keeps it until the priority is cleared.
    public struct Turns: Sendable, Equatable {
        public enum Grant: Sendable, Equatable {
            case same
            /// The other track had it: the engine starts a fresh stream.
            case switched
            /// The engine isn't running: drop this audio.
            case skip
        }

        public static let idleSwitch = 0.4
        public static let maxWait = 4.0

        public private(set) var holder: Track?
        public private(set) var busy = false
        /// Dictation on this track: it doesn't wait for its turn, and the other track waits for it.
        public var priority: Track?
        private var lastDone: Double = -.infinity
        private var waitingSince: [Track: Double] = [:]

        public init() {}

        /// `track` wants to feed now. Nil: not yet (try again shortly).
        public mutating func request(_ track: Track, now: Double) -> Grant? {
            guard !busy, priority == nil || priority == track else {
                if waitingSince[track] == nil { waitingSince[track] = now }
                return nil
            }
            if holder == nil || holder == track {
                take(track)
                return .same
            }
            let waited = now - (waitingSince[track] ?? now)
            if waitingSince[track] == nil { waitingSince[track] = now }
            guard priority == track || now - lastDone >= Self.idleSwitch || waited >= Self.maxWait else { return nil }
            take(track)
            return .switched
        }

        /// The feed `request` granted has finished.
        public mutating func done(_ track: Track, now: Double) {
            guard holder == track else { return }
            busy = false
            lastDone = now
        }

        /// The track's session ended: the other may go at once.
        public mutating func leave(_ track: Track) {
            waitingSince[track] = nil
            if priority == track { priority = nil }
            if holder == track, !busy {
                holder = nil
                lastDone = -.infinity
            }
        }

        /// For starting or stopping the engine: true (and busy) once no feed is running.
        public mutating func claim() -> Bool {
            guard !busy else { return false }
            busy = true
            return true
        }

        public mutating func release() { busy = false }

        private mutating func take(_ track: Track) {
            holder = track
            busy = true
            waitingSince[track] = nil
        }
    }
}

/// One track's view of the shared engine.
// @unchecked: `owner` is under `lock`.
private final class Facade: LiveEngine, @unchecked Sendable {
    let shared: SharedEngine
    let track: SharedEngine.Track
    private let lock = NSLock()
    /// This facade's last start (0: none yet).
    private var owner = 0

    init(shared: SharedEngine, track: SharedEngine.Track) {
        self.shared = shared
        self.track = track
    }

    var name: String { shared.engine.name }
    var modelDelay: String { shared.engine.modelDelay }
    var lookaheadSeconds: Double { shared.engine.lookaheadSeconds }

    func prepare(progress: @escaping @Sendable (Double, String) -> Void) async throws {
        try await shared.engine.prepare(progress: progress)
    }

    func start(onUpdate: @escaping @Sendable (LiveUpdate) -> Void) async throws {
        let owner = try await shared.start(track, onUpdate: onUpdate)
        lock.withLock { self.owner = owner }
    }

    func feed(_ samples: [Float]) async throws { try await shared.feed(track, owner: lock.withLock { owner }, samples) }

    func stop() async { await shared.stop(track, owner: lock.withLock { owner }) }

    func prioritize(_ on: Bool) { shared.prioritize(on ? track : nil) }

    /// The session's own count doesn't know about the other track's turns: the shared engine's does.
    func samplesUntilStep(fed: Int) -> Int { shared.samplesUntilStep(track) }
}
