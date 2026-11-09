import AVFoundation
import Foundation
import os
import Testing
@testable import Sona

struct RecordingFrameTests {
    @Test func chunkerCutsTenthsOfASecondAndKeepsTheRest() {
        var chunker = FrameChunker()
        #expect(chunker.append([Int16](repeating: 1, count: 1000), at: 100).isEmpty)
        #expect(chunker.pending.count == 1000)
        let frames = chunker.append([Int16](repeating: 2, count: 2500), at: 999)  // time only counts when empty
        #expect(frames.count == 2)
        #expect(frames.allSatisfy { $0.samples.count == AudioFrame.samples })
        #expect(frames[0].time == 100)
        #expect(abs(frames[1].time - 100.1) < 1e-9)
        #expect(frames[0].samples[999] == 1 && frames[0].samples[1000] == 2)
        #expect(chunker.pending.count == 300)
    }

    @Test func silenceIsTheFloor() {
        #expect(AudioLevel.decibels([Int16](repeating: 0, count: 1600)) == -100)
        #expect(AudioLevel.decibels([]) == -100)
    }

    @Test func fullScaleIsZeroDecibels() {
        let square = (0..<1600).map { $0 % 2 == 0 ? Int16.max : Int16.min }
        #expect(abs(AudioLevel.decibels(square)) < 0.01)
    }

    @Test func sineLevelIsItsRMS() {
        // Amplitude 0.1: RMS 0.0707, -23.0 dBFS.
        let sine = (0..<1600).map { Int16(0.1 * 32768 * sin(2 * Double.pi * 400 * Double($0) / 16_000)) }
        #expect(abs(AudioLevel.decibels(sine) - 20 * log10(0.1 / 2.0.squareRoot())) < 0.05)
    }

    @Test func waveformLevelMapsAndClamps() {
        #expect(AudioLevel.unit(-100) == 0)
        #expect(AudioLevel.unit(-50) == 0)
        #expect(AudioLevel.unit(-30) == 0.5)
        #expect(AudioLevel.unit(-10) == 1)
        #expect(AudioLevel.unit(0) == 1)
    }

    @Test func floatsAreTheSamplesOver32768() {
        let frame = AudioFrame(samples: [0, 16384, -32768], time: 0, levelDB: 0)
        #expect(frame.floats == [0, 0.5, -1])
    }

    /// A 44.1 kHz stereo file's buffers, as the debug source hands them over: 16 kHz mono frames come out.
    @Test func frameMakerConvertsToSixteenKilohertzMono() throws {
        let format = try #require(AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: 2))
        let frames = OSAllocatedUnfairLock(initialState: [AudioFrame]())
        let maker = try #require(FrameMaker(from: format) { frame in frames.withLock { $0.append(frame) } })
        for tenth in 0..<10 {
            let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 4410))
            buffer.frameLength = 4410
            for channel in 0..<2 {
                for i in 0..<4410 {
                    buffer.floatChannelData![channel][i] = Float(0.3 * sin(2 * Double.pi * 440 * Double(tenth * 4410 + i) / 44_100))
                }
            }
            maker.process(buffer, startingAt: 1000 + Double(tenth) / 10)
        }
        let got = frames.withLock { $0 }
        // A second of audio, less what the resampler holds back.
        #expect((9...10).contains(got.count))
        #expect(got.allSatisfy { $0.samples.count == 1600 })
        #expect(got.first?.time == 1000)
        // A 0.3 sine is about -13.5 dBFS (a little less where the resampler starts up).
        #expect(got.dropFirst().allSatisfy { abs($0.levelDB + 13.5) < 1.5 })
    }
}
