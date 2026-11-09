import Foundation

/// The live waveform's last few seconds, placed on a clock of its own. Audio reaches the main actor unevenly (a few
/// frames at once after the screen was locked, say), and bars drawn as they land stall and jump. So each level is
/// drawn `lag` seconds after it was heard and scrolls left at a steady 10 bars a second, and the lag is just long
/// enough to cover how unevenly the levels come.
nonisolated struct WaveScroll: Equatable, Sendable {
    /// Levels a second: one per 100 ms frame (`AudioFrame`).
    static let rate = 10.0
    /// How many levels it keeps: 8 s, more than the widest wave shows.
    static let keep = 80
    /// How far back it looks to see how late levels come.
    static let window: TimeInterval = 2
    /// Each level is due a slot early on top of the spread, so it slides in from the edge already drawn.
    static let margin: TimeInterval = 1 / rate
    /// Levels that come later than this after the most punctual are drawn late (they pop in) rather than holding the
    /// whole wave back further.
    static let maxSpread: TimeInterval = 0.5
    /// How fast the lag moves, in seconds per second: the wave runs at most 10% fast or slow while it settles, so it
    /// never jumps.
    static let lagSpeed = 0.1
    /// Off by more than this (the clock was changed), the lag jumps straight there.
    static let snapOver: TimeInterval = 1

    nonisolated struct Sample: Equatable, Sendable {
        var level: Float
        /// When it was heard, on the audio's own clock (`AudioFrame.time`).
        var heard: TimeInterval
        /// When it reached the main actor, on the clock the screen draws by (`Date`'s reference-date seconds).
        var arrived: TimeInterval
    }

    /// One slot of the wave. `position`: slots from the right edge, the newest bar at 0 just as it's due and growing
    /// as it scrolls left (-1 is a slot still off the right edge). `level`: 0 where no level is (a dim dot).
    nonisolated struct Bar: Equatable, Sendable {
        var position: Double
        var level: Float
    }

    /// In the order they came (one that came late follows newer ones).
    private(set) var samples: [Sample] = []
    /// The lag at `lagAt`: seconds from a level being heard to it showing at the right edge, on the drawing clock (so
    /// it also takes up the difference between the two clocks). It moves toward `target` at `lagSpeed`.
    private var lagThen: TimeInterval = 0
    private var lagAt: TimeInterval = 0
    private var target: TimeInterval = 0

    var levels: [Float] { samples.map(\.level) }

    mutating func add(_ level: Float, heard: TimeInterval, arrived: TimeInterval) {
        samples.append(Sample(level: level, heard: heard, arrived: arrived))
        if samples.count > Self.keep { samples.removeFirst(samples.count - Self.keep) }
        // How late the recent levels came: the most punctual sets the pace, the spread is the jitter to cover.
        // Either way round: after the clock was set back, the levels from before aren't recent either.
        let delays = samples.filter { abs(arrived - $0.arrived) <= Self.window }.map { $0.arrived - $0.heard }
        let fastest = delays.min() ?? 0
        let spread = min(Self.maxSpread, (delays.max() ?? 0) - fastest)
        let newTarget = fastest + spread + Self.margin
        let current = lag(at: arrived)
        lagThen = samples.count == 1 || abs(newTarget - current) > Self.snapOver ? newTarget : current
        lagAt = arrived
        target = newTarget
    }

    /// The lag at `now`: where it was at the last level, moved toward the target at `lagSpeed`.
    func lag(at now: TimeInterval) -> TimeInterval {
        let reach = Self.lagSpeed * max(0, now - lagAt)
        return lagThen + min(reach, max(-reach, target - lagThen))
    }

    /// Where a level heard at `heard` is at `now`, in slots from the right edge.
    func position(heard: TimeInterval, at now: TimeInterval) -> Double {
        (now - heard - lag(at: now)) * Self.rate
    }

    /// The wave at `now`: `count` slots and one more at each edge, right to left, on a grid that moves with the
    /// newest level that's due. Slots with no level are dots, so the line is always full and scrolls as one.
    func bars(at now: TimeInterval, count: Int) -> [Bar] {
        let placed = samples.map { (position: position(heard: $0.heard, at: now), level: $0.level) }
        // The newest level that's due sets the grid (a level that came late may be listed after newer ones). Before
        // any level is due, the dots stand still.
        let newest = placed.filter { $0.position >= 0 }.min { $0.position < $1.position }
        let phase = newest.map { $0.position.truncatingRemainder(dividingBy: 1) } ?? 0
        return (-1...count).map { slot in
            let position = phase + Double(slot)
            let level = placed.last(where: { abs($0.position - position) < 0.5 })?.level ?? 0
            return Bar(position: position, level: level)
        }
    }
}
