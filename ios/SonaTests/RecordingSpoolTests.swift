import AVFoundation
import Foundation
import SonaEngine
import Testing
@testable import Sona

/// PhoneRecorder end to end, in real time: a test tone through the debug file source, into a spool of its own.
@MainActor
@Suite(.serialized)
struct RecordingSpoolTests {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("spool-\(UUID().uuidString)", isDirectory: true)

    /// A 44.1 kHz stereo WAV of a 440 Hz tone, so the file goes through the same conversion as the mic.
    static func tone(seconds: Double) throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("tone-\(UUID().uuidString).wav")
        let rate = 44_100.0
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: rate, AVNumberOfChannelsKey: 2,
            AVLinearPCMBitDepthKey: 16, AVLinearPCMIsFloatKey: false,
        ]
        let file = try AVAudioFile(forWriting: url, settings: settings)
        let frames = AVAudioFrameCount(seconds * rate)
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: frames))
        buffer.frameLength = frames
        for channel in 0..<2 {
            for i in 0..<Int(frames) { buffer.floatChannelData![channel][i] = Float(0.3 * sin(2 * Double.pi * 440 * Double(i) / rate)) }
        }
        try file.write(from: buffer)
        return url
    }

    func recorder(_ spool: Spool, file: URL?) -> PhoneRecorder {
        let recorder = PhoneRecorder(spool: spool, showsActivity: false) { handlers in FileAudioSource(file: file, handlers: handlers) }
        recorder.checkpointSeconds = 2  // the app flushes every 10 s; 2 keeps the test quick
        return recorder
    }

    /// Polls, so a busy machine slows the test down instead of failing it.
    func waitUntil(seconds: Double = 10, _ condition: () -> Bool) async {
        let deadline = Date().addingTimeInterval(seconds)
        while !condition(), Date() < deadline { try? await Task.sleep(for: .milliseconds(50)) }
    }

    @Test func recordsAFileIntoTheSpool() async throws {
        let spool = Spool(dir: dir)
        let recorder = recorder(spool, file: try Self.tone(seconds: 1))  // then silence
        var finished: [String] = []
        recorder.onFinished = { finished.append($0) }

        try await recorder.start()
        let t0 = Date()
        #expect(recorder.isRecording)
        #expect(recorder.startedAt != nil)
        let id = try #require(spool.openID)
        #expect(spool.load(id)?.closed == false)  // saved at once, so a crash right away still has it

        // Checkpointed while it runs (every 2 s): the entry has caught up, and the audio is on disk.
        await waitUntil { (spool.load(id)?.speechEnd ?? 0) >= 2 && recorder.levels.count >= 20 }
        let open = try #require(spool.load(id))
        #expect(!open.closed && open.speechEnd >= 2)
        #expect(WavFile.duration(of: spool.wav(id)) >= 2)
        // The tone's levels, then silence's.
        #expect(recorder.levels.count >= 20)
        #expect(recorder.levels.prefix(8).allSatisfy { $0 > 0.8 })
        #expect(recorder.levels.suffix(5).allSatisfy { $0 == 0 })

        try await recorder.start()  // already recording: nothing happens
        #expect(spool.openID == id)

        await recorder.stop()
        let elapsed = Date().timeIntervalSince(t0)
        #expect(!recorder.isRecording)
        #expect(recorder.startedAt == nil)
        #expect(recorder.lastError == nil)
        #expect(spool.openID == nil)
        #expect(finished == [id])

        let entry = try #require(spool.load(id))
        #expect(entry.closed)
        #expect(entry.source == "iPhone")
        // Real time: as long as it ran, less at most the last tick and what the resampler holds back.
        let duration = WavFile.duration(of: spool.wav(id))
        #expect(duration > elapsed - 0.4 && duration < elapsed + 0.05)
        #expect(entry.speechEnd == duration && entry.speechSeconds == duration)
        // The header has the real sizes: AVAudioFile reads exactly that much 16 kHz mono.
        let wav = try AVAudioFile(forReading: spool.wav(id))
        #expect(wav.fileFormat.sampleRate == 16_000 && wav.fileFormat.channelCount == 1)
        #expect(Double(wav.length) / 16_000 == duration)
        #expect(spool.pending().map(\.id) == [id])

        await recorder.stop()  // not recording: nothing happens
        #expect(finished == [id])
        try? FileManager.default.removeItem(at: dir)
    }

    @Test func dropsABlipUnderHalfASecond() async throws {
        let spool = Spool(dir: dir)
        let recorder = recorder(spool, file: nil)
        var finished: [String] = []
        recorder.onFinished = { finished.append($0) }

        try await recorder.start()
        try await Task.sleep(for: .seconds(0.1))
        await recorder.stop()
        #expect(!recorder.isRecording)
        #expect(spool.openID == nil)
        #expect(finished.isEmpty)
        #expect(spool.pending().isEmpty)
        #expect((try? FileManager.default.contentsOfDirectory(atPath: dir.path))?.isEmpty == true)
        try? FileManager.default.removeItem(at: dir)
    }

    @Test func aFileThatWontOpenLeavesNothingBehind() async throws {
        let spool = Spool(dir: dir)
        let recorder = recorder(spool, file: dir.appendingPathComponent("missing.wav"))
        await #expect(throws: (any Error).self) { try await recorder.start() }
        #expect(!recorder.isRecording)
        #expect(recorder.lastError != nil)
        #expect(spool.openID == nil)
        #expect(spool.pending().isEmpty)
        try? FileManager.default.removeItem(at: dir)
    }

    @Test func aRecordingThatStartsPausesTheNotePlayingFirst() async throws {
        let note = AudioPlayer()
        note.muted = true
        let audio = try Self.tone(seconds: 3)
        defer { try? FileManager.default.removeItem(at: audio) }
        note.load(audio)
        note.play()
        #expect(note.isPlaying)
        let recorder = recorder(Spool(dir: dir), file: try Self.tone(seconds: 1))
        try await recorder.start()
        // Paused before the session turned to play and record, so the mic never hears the note.
        #expect(!note.isPlaying)
        await recorder.stop()
        try? FileManager.default.removeItem(at: dir)
    }
}
