import AVFoundation
import Foundation
import NotesKit
import SonaEngine
import Testing
@testable import Sona

/// The watch-to-iPhone hop for the watch's AAC, as far as it goes without devices or WatchConnectivity: the file the
/// watch sends, WatchInbox staging it inside the callback, decoding it into the spool after, and the note written from
/// that entry the way the Processor writes one (`NoteWriter.write(_:to:source: entry.source)`), the engine left out.
struct WatchAACTests {
    let dir = makeTempDir()
    var spoolDir: URL { dir.appendingPathComponent("Spool", isDirectory: true) }
    var staging: URL { dir.appendingPathComponent("WatchStaging", isDirectory: true) }
    var notes: URL { dir.appendingPathComponent("Notes/Conversations", isDirectory: true) }
    let started = Date(timeIntervalSince1970: 1_793_000_000)

    func inbox(_ acks: FakeAcknowledger = FakeAcknowledger()) -> WatchInbox {
        WatchInbox(spool: Spool(dir: spoolDir), receivedFile: dir.appendingPathComponent("watch-received.json"), acknowledger: acks)
    }

    func stagedFiles() -> [String] { (try? FileManager.default.contentsOfDirectory(atPath: staging.path)) ?? [] }

    /// AAC in ADTS (an `.aac`, as the watch's recorder writes it), 16 kHz mono, `seconds` of a quiet tone.
    func makeWatchAAC(_ url: URL, seconds: Double) throws {
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: 16_000, AVNumberOfChannelsKey: 1,
            AVEncoderBitRateKey: 32_000,
        ]
        let file = try AVAudioFile(forWriting: url, settings: settings)
        let n = AVAudioFrameCount(seconds * 16_000)
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: n))
        buffer.frameLength = n
        for i in 0..<Int(n) { buffer.floatChannelData![0][i] = Float(sin(Double(i) * 2 * .pi * 220 / 16_000) * 0.3) }
        try file.write(from: buffer)
        file.close()
    }

    /// Half of a frame after the last whole one, as a flat battery leaves it. Returns the file as it was before.
    @discardableResult
    func tear(_ url: URL) throws -> Data {
        let whole = try Data(contentsOf: url)
        let bytes = [UInt8](whole)
        let first = ADTSFile.id3Length(bytes)
        let frame = try #require(ADTSFile.frame(in: bytes, at: first))
        try (whole + Data(bytes[first..<(first + frame.length / 2)])).write(to: url)
        return whole
    }

    /// A pair as `WatchInbox` stages it, written by hand: what an earlier launch left behind.
    func stagePair(seconds: Double, torn: Bool = false) throws -> String {
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
        let id = UUID().uuidString
        let audio = staging.appendingPathComponent("\(id).aac")
        try makeWatchAAC(audio, seconds: seconds)
        if torn { try tear(audio) }
        try JSONEncoder().encode(WatchRecording(id: id, startedAt: started, duration: seconds))
            .write(to: staging.appendingPathComponent("\(id).json"))
        return id
    }

    /// The note the Processor would write for `entry`: the same call, with a made-up transcript of `words`.
    func writeNote(for entry: SpoolEntry, words: [String]) throws -> URL {
        let ws = words.enumerated().map { Word(word: $1, start: Double($0), end: Double($0) + 0.4, speaker: "Speaker 1") }
        let duration = WavFile.duration(of: Spool(dir: spoolDir).wav(entry.id))
        let t = Transcript(
            startedAt: entry.startedAt, duration: duration, text: words.joined(separator: " "), words: ws,
            turns: words.isEmpty ? [] : [Turn(speaker: "Speaker 1", start: 0, end: Double(words.count))], asrSeconds: 0.1,
            diarizationSeconds: 0.1, model: "test")
        return try NoteWriter.write(t, to: notes, source: entry.source)
    }

    @Test func theRecorderWritesADTS() throws {
        let url = dir.appendingPathComponent("watch.aac")
        try makeWatchAAC(url, seconds: 2)
        let seconds = try #require(try ADTSFile.scan(url, repair: false), "AVFoundation's .aac is ADTS")
        #expect(seconds > 1.9 && seconds < 2.6)
        #expect(!WatchInbox.isWAV(url))
    }

    /// Kept as it came and acknowledged inside the callback, decoded into the spool after it, once, however often it
    /// arrives; and it becomes an Apple Watch note.
    @Test func theWatchsAACIsStagedThenConvertedAndBecomesAnAppleWatchNote() throws {
        let url = dir.appendingPathComponent("watch.aac")
        try makeWatchAAC(url, seconds: 2)
        let copy = dir.appendingPathComponent("watch-again.aac")
        try FileManager.default.copyItem(at: url, to: copy)
        let whole = try Data(contentsOf: url)
        // The encoder's priming makes it a little longer than what was written.
        let seconds = try #require(try ADTSFile.scan(url, repair: false))
        let acks = FakeAcknowledger()
        let recording = WatchRecording(startedAt: started, duration: seconds)

        #expect(try inbox(acks).receive(file: url, metadata: recording.metadata) == .staged)
        #expect(acks.acks == [recording.id])
        #expect(!FileManager.default.fileExists(atPath: url.path), "moved out of WCSession's folder inside the callback")
        #expect(try Data(contentsOf: staging.appendingPathComponent("\(recording.id).aac")) == whole)
        let info = try JSONDecoder().decode(
            WatchRecording.self, from: Data(contentsOf: staging.appendingPathComponent("\(recording.id).json")))
        #expect(info.id == recording.id)
        #expect(info.startedAt == started)
        #expect(Spool(dir: spoolDir).pending().isEmpty, "nothing decoded inside the callback")
        #expect(inbox(acks).receivedIDs().contains(recording.id), "the inventory lists it, so the watch lets it go")

        let added = inbox(acks).convertStaged()  // a fresh inbox: after a relaunch, say
        #expect(added.count == 1)
        let spool = Spool(dir: spoolDir)
        let entry = try #require(spool.pending().first)
        #expect(entry.id == added.first)
        #expect(entry.source == NoteSource.watch)
        #expect(entry.closed)
        #expect(entry.startedAt == started)
        #expect(WatchInbox.isSpoolFormat(spool.wav(entry.id)))
        #expect(abs(WavFile.duration(of: spool.wav(entry.id)) - seconds) < 0.1)
        #expect(abs(entry.speechEnd - WavFile.duration(of: spool.wav(entry.id))) < 0.001)
        #expect(stagedFiles().isEmpty, "nothing left staged")

        // Sent again: acknowledged, nothing staged or added twice.
        #expect(try inbox(acks).receive(file: copy, metadata: recording.metadata) == .duplicate)
        #expect(acks.acks == [recording.id, recording.id])
        #expect(inbox(acks).convertStaged().isEmpty)
        #expect(spool.pending().count == 1)

        let md = try writeNote(for: entry, words: ["Remember", "the", "milk", "on", "the", "way", "home."])
        let text = try String(contentsOf: md, encoding: .utf8)
        #expect(text.contains("source: \"Apple Watch\"\n"))
        let note = try NoteStore(root: notes).read(url: md)
        #expect(note.source == NoteSource.watch)
        #expect(note.date == NoteWriter.dayString(started))
    }

    /// The watch cuts a torn last frame off before it sends, but one that arrives with it still on is cut here, so it
    /// still converts and nothing waits in staging for good.
    @Test func anAACWithATornLastFrameIsCutBackAndConverts() throws {
        _ = try stagePair(seconds: 2, torn: true)
        let added = inbox().convertStaged()
        #expect(added.count == 1)
        let entry = try #require(Spool(dir: spoolDir).pending().first)
        #expect(entry.source == NoteSource.watch)
        #expect(entry.startedAt == started)
        #expect(stagedFiles().isEmpty)
    }

    /// A pair an earlier launch received and didn't get to decode converts on the next.
    @Test func aPairLeftByAnEarlierLaunchConverts() throws {
        _ = try stagePair(seconds: 1)
        #expect(inbox().convertStaged().count == 1)
        let entry = try #require(Spool(dir: spoolDir).pending().first)
        let md = try writeNote(for: entry, words: ["Older", "launches", "still", "reach", "the", "notes."])
        #expect(try NoteStore(root: notes).read(url: md).source == NoteSource.watch)
    }

    /// One that can't be decoded yet was acknowledged, so it's the only copy: it stays for next time.
    @Test func aStagedRecordingThatWontDecodeStays() throws {
        let url = dir.appendingPathComponent("broken.aac")
        try Data(repeating: 0x5A, count: 4_000).write(to: url)
        let recording = WatchRecording(startedAt: Date(), duration: 2)
        #expect(try inbox().receive(file: url, metadata: recording.metadata) == .staged)

        #expect(inbox().convertStaged().isEmpty)
        #expect(inbox().convertStaged().isEmpty)
        #expect(FileManager.default.fileExists(atPath: staging.appendingPathComponent("\(recording.id).aac").path))
        #expect(FileManager.default.fileExists(atPath: staging.appendingPathComponent("\(recording.id).json").path))
        #expect(Spool(dir: spoolDir).pending().isEmpty)
    }

    /// After a few failed decodes, the part that decodes becomes the note: the watch let its copy go, so nothing of it
    /// may wait forever.
    @Test func aRecordingThatOnlyPartlyDecodesKeepsWhatDecodesAfterThreeTries() throws {
        let id = try stagePair(seconds: 3)
        let audio = staging.appendingPathComponent("\(id).aac")
        // Garbage after the first half: AVFoundation stops there.
        let whole = try Data(contentsOf: audio)
        try (whole.prefix(whole.count / 2) + Data(repeating: 0xFF, count: 20_000)).write(to: audio)
        var added: [String] = []
        for _ in 0..<WatchInbox.decodeTries {
            added = inbox().convertStaged()
            if !added.isEmpty { break }
        }
        // Either it decoded as a whole (AVFoundation skipped the garbage) or what decodes went in by the third try.
        let spoolID = try #require(added.first)
        let entry = try #require(Spool(dir: spoolDir).load(spoolID))
        #expect(entry.source == NoteSource.watch)
        #expect(WavFile.duration(of: Spool(dir: spoolDir).wav(spoolID)) >= 0.5)
        #expect(stagedFiles().isEmpty)
        #expect(inbox().unreadableCount() == 0)
    }

    /// Nothing decodes at all: kept staged, and counted for Home's banner once its tries are used up.
    @Test func aRecordingThatNeverDecodesIsCountedAsUnreadable() throws {
        let url = dir.appendingPathComponent("broken.aac")
        try Data(repeating: 0x5A, count: 4_000).write(to: url)
        let recording = WatchRecording(startedAt: Date(), duration: 2)
        #expect(try inbox().receive(file: url, metadata: recording.metadata) == .staged)
        for n in 1...WatchInbox.decodeTries {
            #expect(inbox().unreadableCount() == 0, "not yet, after \(n - 1) tries")
            #expect(inbox().convertStaged().isEmpty)
        }
        #expect(inbox().unreadableCount() == 1)
        #expect(FileManager.default.fileExists(atPath: staging.appendingPathComponent("\(recording.id).aac").path))
        #expect(Spool(dir: spoolDir).pending().isEmpty)
    }

    /// Under half a second (a double tap) is acknowledged and staged like any other, then dropped, not kept.
    @Test func aVeryShortAACIsDropped() throws {
        _ = try stagePair(seconds: 0.2)
        #expect(inbox().convertStaged().isEmpty)
        #expect(Spool(dir: spoolDir).pending().isEmpty)
        #expect(stagedFiles().isEmpty)
    }

    /// Raw audio, like the spool: kept out of backups.
    @Test func theStagingFolderIsOutOfBackups() throws {
        let url = dir.appendingPathComponent("watch.aac")
        try makeWatchAAC(url, seconds: 1)
        _ = try inbox().receive(file: url, metadata: WatchRecording(startedAt: started, duration: 1).metadata)
        let values = try staging.resourceValues(forKeys: [.isExcludedFromBackupKey])
        #expect(values.isExcludedFromBackup == true)
    }

    /// The watch's WAV (an older build's, or its fallback) still goes straight into the spool, and a recording with no
    /// words is still a note, from the watch.
    @Test func aWatchWAVStillGoesStraightToTheSpool() throws {
        let url = dir.appendingPathComponent("incoming.wav")
        try makeSpoolWAV(url, seconds: 1.5)
        let recording = WatchRecording(startedAt: started, duration: 1.5)
        let acks = FakeAcknowledger()

        let outcome = try inbox(acks).receive(file: url, metadata: recording.metadata)
        guard case .added(let spoolID) = outcome else {
            Issue.record("not added: \(outcome)")
            return
        }
        #expect(acks.acks == [recording.id])
        #expect(stagedFiles().isEmpty, "a WAV isn't staged")
        let entry = try #require(Spool(dir: spoolDir).load(spoolID))
        #expect(entry.source == NoteSource.watch)
        #expect(entry.closed)
        #expect(abs(entry.speechEnd - 1.5) < 0.01)

        let md = try writeNote(for: entry, words: [])
        let note = try NoteStore(root: notes).read(url: md)
        #expect(note.title == "No speech transcribed")
        #expect(note.source == NoteSource.watch)
        #expect(NoteSource.isDeliberate(entry.source), "so the Processor keeps it")
    }
}
