import Foundation
import SonaEngine
import Testing
@testable import Sona

/// A pause in the middle of a recording (a call had the mic) keeps its place in time: silence fills it, so the words
/// after it keep their real times in the note.
struct RecordingGapTests {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("pause-\(UUID().uuidString)", isDirectory: true)

    func frames(_ count: Int, from start: TimeInterval) -> [AudioFrame] {
        (0..<count).map { i in
            AudioFrame(
                samples: [Int16](repeating: 1000, count: AudioFrame.samples), time: start + Double(i) * 0.1, levelDB: -20)
        }
    }

    func record(_ frames: [AudioFrame]) async throws -> Double {
        let spool = Spool(dir: dir)
        let recording = try SpoolRecording(spool: spool, startedAt: Date(timeIntervalSince1970: frames[0].time), source: "iPhone") { _ in }
        for frame in frames { recording.append(frame) }
        return try #require(await recording.finish())
    }

    @Test func aLongPauseIsKeptAsSilence() async throws {
        let t0 = 1_793_000_000.0
        // 1 s of audio, the mic away for 5 s, then 1 s more.
        let seconds = try await record(frames(10, from: t0) + frames(10, from: t0 + 1 + 5))
        #expect(abs(seconds - 7) < 0.15)
    }

    @Test func clockWobbleIsNotAPause() async throws {
        let t0 = 1_793_000_000.0
        // A 1 s hole: under the threshold, so the audio stays back to back.
        let seconds = try await record(frames(10, from: t0) + frames(10, from: t0 + 1 + 1))
        #expect(abs(seconds - 2) < 0.15)
    }
}
