import XCTest

@testable import LiveCore

final class TimeMapTests: XCTestCase {
    func testEmptyAndContiguousMapsAreIdentity() {
        var m = TimeMap()
        XCTAssertEqual(m.sessionSample(fed: 1234), 1234)
        m.append(sessionStart: 0, count: 1000)
        m.append(sessionStart: 1000, count: 500)
        XCTAssertEqual(m.segments.count, 1)
        XCTAssertEqual(m.sessionSample(fed: 1499), 1499)
        XCTAssertEqual(m.sessionSeconds(fedSeconds: 0.05), 0.05, accuracy: 1e-9)
    }

    func testGapsShiftLaterAudio() {
        var m = TimeMap()
        m.append(sessionStart: 0, count: 16_000)  // 0-1 s
        m.append(sessionStart: 48_000, count: 8_000)  // 3-3.5 s, after 2 s of skipped silence
        m.append(sessionStart: 56_000, count: 8_000)  // continues the same stretch
        m.append(sessionStart: 160_000, count: 16_000)  // 10-11 s
        XCTAssertEqual(m.segments.count, 3)
        XCTAssertEqual(m.fedCount, 48_000)
        XCTAssertEqual(m.sessionSample(fed: 15_999), 15_999)
        XCTAssertEqual(m.sessionSample(fed: 16_000), 48_000)
        XCTAssertEqual(m.sessionSample(fed: 31_999), 63_999)
        XCTAssertEqual(m.sessionSample(fed: 32_000), 160_000)
        XCTAssertEqual(m.sessionSeconds(fedSeconds: 1.5), 3.5, accuracy: 1e-9)
        XCTAssertEqual(m.sessionSeconds(fedSeconds: 2.25), 10.25, accuracy: 1e-9)
        // An engine's flush past the end carries on from the last stretch.
        XCTAssertEqual(m.sessionSeconds(fedSeconds: 3.5), 11.5, accuracy: 1e-9)
    }
}

final class SpeakerFrameMapperTests: XCTestCase {
    func testUngappedFramesPassThrough() {
        var m = TimeMap()
        m.append(sessionStart: 0, count: 16_000)
        var f = SpeakerFrameMapper()
        XCTAssertEqual(f.map([0, 0, 1], with: m), [0, 0, 1])
        XCTAssertEqual(f.map([1], with: m), [1])
        XCTAssertEqual(f.nextSessionFrame, 4)
    }

    func testGapIsFilledWithNobody() {
        var m = TimeMap()
        m.append(sessionStart: 0, count: 480)  // 3 frames
        m.append(sessionStart: 1_600, count: 480)  // resumes at frame 10
        var f = SpeakerFrameMapper()
        // Frames can arrive split anywhere, even across the gap.
        let a = f.map([0, 0], with: m)
        let b = f.map([0, 1, 1, 1], with: m)
        XCTAssertEqual(a + b, [0, 0, 0, -1, -1, -1, -1, -1, -1, -1, 1, 1, 1])
        // The timeline then answers in session time: nobody in the gap, speaker 1 after it.
        var t = SpeakerTimeline()
        t.append(a + b)
        XCTAssertEqual(t.speaker(from: 0, to: 0.03), 0)
        XCTAssertNil(t.speaker(from: 0.04, to: 0.09))
        XCTAssertEqual(t.speaker(from: 0.1, to: 0.13), 1)
        XCTAssertEqual(t.coveredSeconds, 0.13, accuracy: 1e-9)
    }

    func testGapNotOnAFrameBoundary() {
        var m = TimeMap()
        m.append(sessionStart: 0, count: 320)
        m.append(sessionStart: 1_000, count: 640)  // 1000 isn't a multiple of 160
        var f = SpeakerFrameMapper()
        let out = f.map([0, 0, 1, 1, 1, 1], with: m)
        // Fed frames 2... start at session sample 1000 + 160k, i.e. frames 6, 7, 8, 9.
        XCTAssertEqual(out, [0, 0, -1, -1, -1, -1, 1, 1, 1, 1])
    }
}

final class VoiceGateTests: XCTestCase {
    private func gate(hangover: Double = 0.2, preRoll: Double = 0.1) -> VoiceGate {
        var c = VoiceGate.Config()
        c.hangoverSeconds = hangover
        c.preRollSeconds = preRoll
        return VoiceGate(vad: nil, config: c)
    }

    func testClosedGateHoldsAudioAndOpensWithPreRoll() {
        let g = gate()
        // 1 s of audio, each sample its own index, so pieces show where they came from.
        XCTAssertNil(g.accept((0..<16_000).map(Float.init)))
        XCTAssertFalse(g.isOpen)
        XCTAssertNil(g.step(probability: 0.1, hopEnd: 8_000))
        let piece = g.step(probability: 0.9, hopEnd: 12_000)
        XCTAssertTrue(g.isOpen)
        // Pre-roll (0.1 s) before the 4096-sample window that heard speech, through everything received.
        let start = 12_000 - VoiceGate.window - 1_600
        XCTAssertEqual(piece?.start, start)
        XCTAssertEqual(piece?.samples.count, 16_000 - start)
        XCTAssertEqual(piece?.samples.first, Float(start))
        // While open, new audio goes straight out, contiguous with the last piece.
        let next = g.accept([1, 2, 3])
        XCTAssertEqual(next?.start, 16_000)
        XCTAssertEqual(next?.samples, [1, 2, 3])
    }

    func testHangoverThenCloseThenReopenWithoutRefeeding() {
        let g = gate(hangover: 0.2)
        _ = g.accept([Float](repeating: 0, count: 32_000))
        let first = g.step(probability: 0.9, hopEnd: 8_000)!
        XCTAssertEqual(first.start + first.samples.count, 32_000)
        // Quiet, but shorter than the hangover: still open. A middling probability keeps it open too.
        g.step(probability: 0.1, hopEnd: 9_600)
        g.step(probability: 0.4, hopEnd: 10_000)
        g.step(probability: 0.1, hopEnd: 12_000)
        XCTAssertTrue(g.isOpen)
        g.step(probability: 0.1, hopEnd: 10_000 + 3_200)
        XCTAssertFalse(g.isOpen)
        XCTAssertNil(g.accept([Float](repeating: 0, count: 16_000)))
        // Reopening never repeats audio already fed, even if the pre-roll reaches back into it.
        let again = g.step(probability: 0.8, hopEnd: 36_000)!
        XCTAssertEqual(again.start, 32_000)
        XCTAssertEqual(again.samples.count, 16_000)
    }

    func testForceOpenReleasesWhatsWaiting() {
        let g = gate(preRoll: 0.5)
        _ = g.accept([Float](repeating: 0, count: 20_000))
        let piece = g.forceOpen()
        XCTAssertEqual(piece?.start, 20_000 - 8_000)
        XCTAssertTrue(g.isOpen)
        // A forced-open gate never closes.
        g.step(probability: 0, hopEnd: 1_000_000)
        XCTAssertTrue(g.isOpen)
    }
}
