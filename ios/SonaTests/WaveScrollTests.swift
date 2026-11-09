import Foundation
import Testing
@testable import Sona

/// The recording screen's live wave (`WaveScroll`): it scrolls at a steady 10 bars a second however unevenly the
/// levels reach the main actor, so it never stalls or jumps the way it did once the bars stopped animating.
struct WaveScrollTests {
    /// The drawing clock's seconds (`Date`'s reference date) and the mic's (monotonic, since boot) are far apart: only
    /// differences may matter.
    static let screenClock: TimeInterval = 784_000_000
    static let micClock: TimeInterval = 500_000
    /// What the lag carries for the clocks alone, on top of how late the levels come.
    static let clocks = screenClock - micClock

    /// Levels heard every 0.1 s from `micClock`, level k reaching the main actor `arrival(k)` seconds into the recording
    /// (nil: never, a gap), in the order they were heard when several come at once, as the mic hands them over. The
    /// screen draws 60 frames a second up to `end`, adding first every level that has come by then.
    static func run(
        until end: TimeInterval, arrival: (Int) -> TimeInterval?, frame: (TimeInterval, WaveScroll) -> Void
    ) {
        let levels = (0..<Int(end * WaveScroll.rate)).compactMap { k -> (k: Int, heard: TimeInterval, arrived: TimeInterval)? in
            guard let arrived = arrival(k) else { return nil }
            return (k, micClock + Double(k) / WaveScroll.rate, screenClock + arrived)
        }.sorted { ($0.arrived, $0.k) < ($1.arrived, $1.k) }
        var wave = WaveScroll()
        var next = 0
        for step in 0...Int(end * 60) {
            let now = screenClock + Double(step) / 60
            while next < levels.count, levels[next].arrived <= now {
                wave.add(0.5, heard: levels[next].heard, arrived: levels[next].arrived)
                next += 1
            }
            frame(now, wave)
        }
    }

    /// How far a level heard at `heard` (seconds into the recording) moved between frames: the scroll's speed.
    static func steps(heard: TimeInterval, arrival: @escaping (Int) -> TimeInterval?, from: TimeInterval, to: TimeInterval) -> [Double] {
        var last: Double?
        var steps: [Double] = []
        run(until: to, arrival: arrival) { now, wave in
            guard now - screenClock >= from, !wave.samples.isEmpty else { return }
            let position = wave.position(heard: micClock + heard, at: now)
            if let last { steps.append(position - last) }
            last = position
        }
        return steps
    }

    /// Each level 0.12 s after it was heard.
    static let steady: (Int) -> TimeInterval? = { k in Double(k) / WaveScroll.rate + 0.12 }
    /// Four at once every 0.4 s, 0.05 s after the last of them was heard: how a mic tap can hand them over after the
    /// screen was locked.
    static let bursts: (Int) -> TimeInterval? = { k in Double(k / 4) * 0.4 + 0.35 }

    static let frameStep = WaveScroll.rate / 60

    @Test func steadyLevelsScrollAtTenBarsASecond() {
        let steps = Self.steps(heard: 2, arrival: Self.steady, from: 1, to: 6)
        #expect(steps.count > 200)
        #expect(steps.allSatisfy { abs($0 - Self.frameStep) < 1e-4 })
    }

    @Test func levelsInBurstsScrollJustAsSteadily() {
        let steps = Self.steps(heard: 2, arrival: Self.bursts, from: 1, to: 6)
        #expect(steps.count > 200)
        #expect(steps.allSatisfy { abs($0 - Self.frameStep) < 1e-4 })
    }

    @Test func burstsNeverLeaveAHoleInTheWave() {
        var checked = 0
        Self.run(until: 6, arrival: Self.bursts) { now, wave in
            guard now - Self.screenClock >= 2, now - Self.screenClock <= 5 else { return }
            for bar in wave.bars(at: now, count: 48) where bar.position > -0.5 {
                // When the level on this slot was heard, in seconds into the recording: none before the first.
                let heard = now - wave.lag(at: now) - bar.position / WaveScroll.rate - Self.micClock
                guard heard > -0.05 else { continue }
                #expect(bar.level == 0.5)
                checked += 1
            }
        }
        #expect(checked > 1000)
    }

    @Test func aGapIsDotsOnTheSameGrid() {
        // Heard 0-2 s and 3-5 s; nothing reached the screen for the second between (off screen, say).
        var bars: [WaveScroll.Bar] = []
        var lag: TimeInterval = 0
        Self.run(until: 5.5, arrival: { k in (20..<30).contains(k) ? nil : Double(k) / WaveScroll.rate + 0.1 }) { now, wave in
            guard abs(now - Self.screenClock - 5.4) < 0.5 / 60 else { return }
            bars = wave.bars(at: now, count: 48)
            lag = wave.lag(at: now)
        }
        #expect(bars.count == 50)
        for (left, right) in zip(bars.dropFirst(), bars) { #expect(abs(left.position - right.position - 1) < 1e-6) }
        for bar in bars {
            let heard = Self.screenClock + 5.4 - lag - bar.position / WaveScroll.rate - Self.micClock
            if heard > 0.05, heard < 1.95 || heard > 3.05 && heard < 4.95 { #expect(bar.level == 0.5) }
            if heard > 2.05, heard < 2.95 { #expect(bar.level == 0) }
        }
    }

    @Test func beforeAnyLevelTheDotsStandStill() {
        let empty = WaveScroll()
        let bars = empty.bars(at: Self.screenClock, count: 48)
        #expect(bars.count == 50)
        #expect(bars.map(\.position) == (-1...48).map(Double.init))
        #expect(bars.allSatisfy { $0.level == 0 })
        #expect(empty.bars(at: Self.screenClock + 3, count: 48) == bars)
        // A level that isn't due yet doesn't move them either.
        var one = WaveScroll()
        one.add(0.7, heard: Self.micClock, arrived: Self.screenClock)
        #expect(one.bars(at: Self.screenClock, count: 48).map(\.position) == bars.map(\.position))
    }

    @Test func theLagSettlesGraduallyAndStaysInBounds() {
        // Steady (0.1 s late) for 3 s, then in bursts up to 0.4 s late: the lag goes from 0.2 to 0.5 at 0.1 s a second.
        let arrival: (Int) -> TimeInterval? = { k in k < 32 ? Double(k) / WaveScroll.rate + 0.1 : Double(k / 4) * 0.4 + 0.4 }
        var previous: TimeInterval?
        var worst = 0.0
        Self.run(until: 9, arrival: arrival) { now, wave in
            guard !wave.samples.isEmpty else { return }
            let lag = wave.lag(at: now) - Self.clocks
            if let previous { worst = max(worst, abs(lag - previous)) }
            previous = lag
            #expect(lag > 0.2 - 1e-6 && lag < 0.5 + 1e-6)
            if now - Self.screenClock < 3 { #expect(abs(lag - 0.2) < 1e-6) }
            if now - Self.screenClock > 7 { #expect(abs(lag - 0.5) < 1e-6) }
        }
        // Never more than 10% of a frame's time in one frame: the wave runs a little slow, never stops or jumps.
        #expect(worst > 0)
        #expect(worst <= WaveScroll.lagSpeed / 60 + 1e-6)
        // So the scroll itself never stops, jumps or goes back while it settles.
        let steps = Self.steps(heard: 5, arrival: arrival, from: 1, to: 9)
        #expect(steps.allSatisfy { $0 > 0.9 * Self.frameStep - 1e-4 && $0 < Self.frameStep + 1e-4 })
    }

    @Test func levelsVeryLateArePoppedInRatherThanHoldingTheWaveBack() {
        // One in four comes 2 s late: the lag covers at most half a second of spread.
        var lag: TimeInterval = 0
        let arrival: (Int) -> TimeInterval? = { k in Double(k) / WaveScroll.rate + (k % 4 == 0 ? 2 : 0.1) }
        Self.run(until: 9, arrival: arrival) { now, wave in lag = wave.lag(at: now) - Self.clocks }
        #expect(abs(lag - (0.1 + WaveScroll.maxSpread + WaveScroll.margin)) < 1e-6)
    }

    @Test func aClockChangeMovesTheLagAtOnce() {
        var wave = WaveScroll()
        for k in 0..<20 { wave.add(0.5, heard: Double(k) / 10, arrived: Double(k) / 10 + 0.1) }
        #expect(abs(wave.lag(at: 2) - 0.2) < 1e-9)
        // The screen's clock was set 30 s back.
        wave.add(0.5, heard: 2, arrived: 2.1 - 30)
        #expect(wave.lag(at: 2.1 - 30) < -29)
    }

    @Test func itKeepsEightSeconds() {
        var wave = WaveScroll()
        for k in 0..<100 { wave.add(Float(k) / 100, heard: Double(k) / 10, arrived: Double(k) / 10 + 0.1) }
        #expect(wave.samples.count == WaveScroll.keep)
        #expect(wave.levels.first == 0.2)
        #expect(wave.levels.last == 0.99)
    }
}
