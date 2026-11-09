import AVFoundation
import Foundation
import NotesKit
import SonaEngine
import Testing
@testable import Sona

/// Stands in for WCSession: remembers each acknowledgement.
final class FakeAcknowledger: WatchAcknowledging, @unchecked Sendable {
    private let lock = NSLock()
    private var ids: [String] = []
    var acks: [String] { lock.withLock { ids } }
    func acknowledge(_ id: String) { lock.withLock { ids.append(id) } }
}

struct WatchReceiverTests {
    let dir = makeTempDir()

    func inbox(_ acks: FakeAcknowledger) -> WatchInbox {
        WatchInbox(spool: Spool(dir: dir.appendingPathComponent("Spool")), receivedFile: dir.appendingPathComponent("received.json"), acknowledger: acks)
    }

    /// What WCSession hands over: a file in its inbox, deleted after the callback.
    func incoming(seconds: Double) throws -> URL {
        let url = dir.appendingPathComponent("incoming-\(UUID().uuidString).wav")
        try makeSpoolWAV(url, seconds: seconds)
        return url
    }

    @Test func aRecordingSentTwiceIsKeptOnceAndAcknowledgedTwice() throws {
        let acks = FakeAcknowledger()
        let started = Date(timeIntervalSince1970: 1_793_000_000)
        let recording = WatchRecording(startedAt: started, duration: 2)

        let first = try inbox(acks).receive(file: try incoming(seconds: 2), metadata: recording.metadata)
        guard case .added(let spoolID) = first else { Issue.record("not added: \(first)"); return }
        // A fresh inbox (the app relaunched) still knows it.
        let second = try inbox(acks).receive(file: try incoming(seconds: 2), metadata: recording.metadata)
        #expect(second == .duplicate)
        #expect(acks.acks == [recording.id, recording.id])

        let spool = Spool(dir: dir.appendingPathComponent("Spool"))
        let entries = spool.pending()
        #expect(entries.count == 1)
        let entry = try #require(entries.first)
        #expect(entry.id == spoolID)
        #expect(entry.source == "Apple Watch")
        #expect(entry.closed)
        #expect(entry.startedAt == started)
        #expect(abs(entry.speechEnd - 2) < 0.01)
        #expect(entry.speechSeconds == entry.speechEnd)
        #expect(abs(WavFile.duration(of: spool.wav(spoolID)) - 2) < 0.01)
    }

    /// A double tap on the watch: acknowledged so the watch lets it go, never put in the spool (the model can't take
    /// it, so it would only fail).
    @Test func aRecordingUnderHalfASecondIsAcknowledgedNotKept() throws {
        let acks = FakeAcknowledger()
        let recording = WatchRecording(startedAt: Date(), duration: 0.2)
        #expect(try inbox(acks).receive(file: try incoming(seconds: 0.2), metadata: recording.metadata) == .tooShort)
        #expect(acks.acks == [recording.id])
        #expect(Spool(dir: dir.appendingPathComponent("Spool")).pending().isEmpty)
    }

    @Test func otherFilesAreIgnored() throws {
        let acks = FakeAcknowledger()
        #expect(try inbox(acks).receive(file: try incoming(seconds: 1), metadata: ["kind": "something else"]) == .ignored)
        #expect(acks.acks.isEmpty)
        #expect(Spool(dir: dir.appendingPathComponent("Spool")).pending().isEmpty)
    }

    /// The watch's own WAV (16 kHz mono 16-bit, AVFoundation's 4 KB header) is copied into the spool bit for bit
    /// behind a 44-byte header, not decoded; one cut off by a crash (sizes 0) keeps everything on disk.
    @Test func theWatchsOwnLayoutIsCopiedNotConverted() throws {
        let url = dir.appendingPathComponent("watch.wav")
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: 16_000, AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 16, AVLinearPCMIsFloatKey: false,
        ]
        do {
            let file = try AVAudioFile(forWriting: url, settings: settings, commonFormat: .pcmFormatInt16, interleaved: true)
            let buffer = try #require(AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: 32_000))
            buffer.frameLength = 32_000
            for i in 0..<32_000 { buffer.int16ChannelData![0][i] = Int16(truncatingIfNeeded: (i * 37) % 20_000 - 10_000) }
            try file.write(from: buffer)
            file.close()
        }
        let original = try Data(contentsOf: url)
        let samples = try #require(WatchInbox.spoolSamples(in: url))
        #expect(samples.lowerBound > 44)  // the long header
        let sent = Data(original[samples])
        // As a crash leaves it: the data size says 0.
        var cut = original
        let sizeAt = samples.lowerBound - 4
        cut.replaceSubrange(sizeAt..<(sizeAt + 4), with: Data([0, 0, 0, 0]))
        try cut.write(to: url)

        let outcome = try inbox(FakeAcknowledger()).receive(file: url, metadata: WatchRecording(startedAt: Date(), duration: 2).metadata)
        guard case .added(let spoolID) = outcome else { Issue.record("not added: \(outcome)"); return }
        let wav = Spool(dir: dir.appendingPathComponent("Spool")).wav(spoolID)
        #expect(WatchInbox.isSpoolFormat(wav))
        #expect(abs(WavFile.duration(of: wav) - 2) < 0.001)
        #expect(try Data(contentsOf: wav).dropFirst(44) == sent)
    }

    /// A WAV as AVFoundation writes it (a 4 KB header, 48 kHz) is converted to the spool's format, not misread.
    @Test func anotherWAVLayoutIsConverted() throws {
        let url = dir.appendingPathComponent("avfoundation.wav")
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: 48_000, AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 16, AVLinearPCMIsFloatKey: false,
        ]
        do {
            let file = try AVAudioFile(forWriting: url, settings: settings)
            let buffer = try #require(AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: 72_000))
            buffer.frameLength = 72_000
            for i in 0..<72_000 { buffer.floatChannelData![0][i] = Float(sin(Double(i) * 2 * .pi * 220 / 48_000) * 0.3) }
            try file.write(from: buffer)
            file.close()
        }
        #expect(!WatchInbox.isSpoolFormat(url))
        let acks = FakeAcknowledger()
        let outcome = try inbox(acks).receive(file: url, metadata: WatchRecording(startedAt: Date(), duration: 1.5).metadata)
        guard case .added(let spoolID) = outcome else { Issue.record("not added: \(outcome)"); return }
        let wav = Spool(dir: dir.appendingPathComponent("Spool")).wav(spoolID)
        #expect(WatchInbox.isSpoolFormat(wav))
        #expect(abs(WavFile.duration(of: wav) - 1.5) < 0.05)
        #expect(acks.acks.count == 1)
    }
}
