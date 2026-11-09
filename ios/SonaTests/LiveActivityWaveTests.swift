import Foundation
import Testing
@testable import Sona

/// The Live Activity's voice wave: what an update carries (`ActivityWave`), what the bars draw, and the recorder's
/// running few seconds of levels (`WaveLevels`).
struct LiveActivityWaveTests {
    @Test func anUpdateCarriesTheNewestFourSecondsAsPercents() {
        let levels = (0..<100).map { Float($0) / 100 }
        let encoded = ActivityWave.encode(levels)
        #expect(encoded.count == ActivityWave.count)
        #expect(encoded.first == 60)
        #expect(encoded.last == 99)
        // Out of range, or not a number, never wraps a UInt8.
        #expect(ActivityWave.encode([-1, 2, .nan, .infinity]) == [0, 100, 0, 0])
        #expect(ActivityWave.encode([]).isEmpty)
    }

    @Test func theBarsArePaddedWithSilenceOnTheLeft() {
        let heights = ActivityWave.heights([50, 100], bars: 4)
        #expect(heights == [0, 0, 0.5, 1])
        #expect(ActivityWave.heights(nil, bars: 3) == [0, 0, 0])
        #expect(ActivityWave.heights([10], bars: 0).isEmpty)
        // Anything over 100 (an update from a build that scaled differently) is a full bar, not a taller one.
        #expect(ActivityWave.heights([255], bars: 1) == [1])
    }

    @Test func quietMeansUnderTheFaintDots() {
        #expect(ActivityWave.isQuiet([0, 1, 2]))
        #expect(!ActivityWave.isQuiet([0, 3, 0]))
        #expect(ActivityWave.isQuiet([UInt8]()))
    }

    @Test func fewerBarsShowTheNewestLevels() {
        let heights = ActivityWave.heights([10, 20, 30, 40, 50, 60], bars: 3)
        #expect(heights == [0.4, 0.5, 0.6])
    }

    @Test func anActivityWithAWaveRoundTripsAndOneWithoutStillDecodes() throws {
        let state = RecordingAttributes.ContentState(startedAt: Date(timeIntervalSince1970: 783_820_800), levels: [0, 42, 100])
        let decoded = try JSONDecoder().decode(
            RecordingAttributes.ContentState.self, from: JSONEncoder().encode(state))
        #expect(decoded == state)
        let old = try JSONDecoder().decode(
            RecordingAttributes.ContentState.self, from: Data(#"{"startedAt":783820800}"#.utf8))
        #expect(old.levels == nil)
        // An update well under ActivityKit's 4 KB.
        let full = RecordingAttributes.ContentState(
            startedAt: .now, pausedAt: .now, stopReason: "out of space",
            levels: [UInt8](repeating: 100, count: ActivityWave.count))
        #expect(try JSONEncoder().encode(full).count < 1024)
    }

    @Test func theRecorderKeepsOnlyTheLastFewSeconds() {
        let wave = WaveLevels()
        for i in 0..<(ActivityWave.count + 7) { wave.add(Float(i)) }
        let kept = wave.snapshot()
        #expect(kept.count == ActivityWave.count)
        #expect(kept.first == 7)
        #expect(kept.last == Float(ActivityWave.count + 6))
        wave.reset()
        #expect(wave.snapshot().isEmpty)
    }
}
