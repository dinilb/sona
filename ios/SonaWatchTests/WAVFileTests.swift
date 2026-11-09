import Foundation
import Testing
@testable import SonaWatch

/// A WAV like the one AVAudioRecorder leaves when the watch dies mid-recording: 16 kHz mono 16-bit, a FLLR chunk
/// before `data`, and both sizes still 0 (it only writes them at stop).
func synthesizedWAV(samples: Int, riffSize: UInt32 = 0, dataSize: UInt32 = 0, extraBytes: Int = 0) -> Data {
    var wav = Data("RIFF".utf8) + WAVFile.littleEndian(riffSize) + Data("WAVE".utf8)
    wav += Data("fmt ".utf8) + WAVFile.littleEndian(UInt32(16))
    wav += WAVFile.littleEndian(UInt16(1)) + WAVFile.littleEndian(UInt16(1))  // PCM, mono
    wav += WAVFile.littleEndian(UInt32(16_000)) + WAVFile.littleEndian(UInt32(32_000))  // rate, bytes a second
    wav += WAVFile.littleEndian(UInt16(2)) + WAVFile.littleEndian(UInt16(16))  // bytes a frame, bits
    wav += Data("FLLR".utf8) + WAVFile.littleEndian(UInt32(4012)) + Data(count: 4012)
    wav += Data("data".utf8) + WAVFile.littleEndian(dataSize)
    wav += Data((0..<samples * 2 + extraBytes).map { UInt8(truncatingIfNeeded: $0 &* 31) })
    return wav
}

func temporaryFolder() throws -> URL {
    let dir = FileManager.default.temporaryDirectory.appending(path: "sona-tests-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir
}

struct WAVFileTests {
    @Test func readsTheFormatPastOtherChunks() throws {
        let info = try #require(WAVFile.info(of: synthesizedWAV(samples: 10)))
        #expect(info.sampleRate == 16_000)
        #expect(info.channels == 1)
        #expect(info.bitsPerSample == 16)
        #expect(info.dataStart == 12 + 24 + 8 + 4012 + 8)
        #expect(info.dataSize == 0)
    }

    @Test func repairsTheSizesOfACutOffRecording() throws {
        let url = try temporaryFolder().appending(path: "cut.wav")
        try synthesizedWAV(samples: 24_000).write(to: url)  // 1.5 s

        let seconds = try WAVFile.repair(url, force: true)

        #expect(seconds == 1.5)
        let repaired = try Data(contentsOf: url)
        let info = try #require(WAVFile.info(of: repaired))
        #expect(Int(info.dataSize) == 48_000)
        #expect(Int(info.riffSize) == repaired.count - 8)
        #expect(info.dataStart + Int(info.dataSize) == repaired.count)
    }

    @Test func cutsOffAHalfWrittenSample() throws {
        let url = try temporaryFolder().appending(path: "odd.wav")
        try synthesizedWAV(samples: 16_000, extraBytes: 1).write(to: url)

        let seconds = try WAVFile.repair(url, force: false)  // a data size of 0 is broken even unforced

        #expect(seconds == 1)
        let repaired = try Data(contentsOf: url)
        let info = try #require(WAVFile.info(of: repaired))
        #expect(info.dataSize == 32_000)
        #expect(repaired.count == info.dataStart + 32_000)
    }

    @Test func leavesAFinishedRecordingAlone() throws {
        let url = try temporaryFolder().appending(path: "done.wav")
        let length = synthesizedWAV(samples: 8_000).count
        let finished = synthesizedWAV(samples: 8_000, riffSize: UInt32(length - 8), dataSize: 16_000)
        try finished.write(to: url)

        #expect(try WAVFile.repair(url, force: false) == 0.5)
        #expect(try Data(contentsOf: url) == finished)
    }

    @Test func notAWAV() throws {
        let url = try temporaryFolder().appending(path: "junk.wav")
        try Data("not audio at all".utf8).write(to: url)
        #expect(try WAVFile.repair(url, force: true) == nil)
    }
}

struct RecoveryTests {
    @Test func aRecordingThatNeverStoppedIsRepairedAndKeepsItsID() throws {
        let store = RecordingStore(dir: try temporaryFolder())
        let cut = WatchRecording(startedAt: Date(timeIntervalSince1970: 1_000), duration: 0)
        try store.save(cut)
        try synthesizedWAV(samples: 32_000).write(to: store.wavURL(cut.id))  // 2 s

        #expect(store.recover() == [cut.id])

        let recovered = try #require(store.load(cut.id))
        #expect(recovered.duration == 2)
        #expect(recovered.startedAt == cut.startedAt)
        let info = try #require(WAVFile.info(of: Data(contentsOf: store.wavURL(cut.id))))
        #expect(info.dataSize == 64_000)
    }

    @Test func aWAVWithoutItsJSONGetsOne() throws {
        let store = RecordingStore(dir: try temporaryFolder())
        let id = UUID().uuidString
        try synthesizedWAV(samples: 16_000).write(to: store.wavURL(id))

        store.recover()

        #expect(store.load(id)?.duration == 1)
    }

    @Test func aRecordingWithNoAudioIsRemoved() throws {
        let store = RecordingStore(dir: try temporaryFolder())
        let empty = WatchRecording(startedAt: Date(), duration: 0)
        try store.save(empty)
        try synthesizedWAV(samples: 0).write(to: store.wavURL(empty.id))
        let orphan = WatchRecording(startedAt: Date(), duration: 3)  // its WAV is gone
        try store.save(orphan)

        #expect(store.recover().isEmpty)
        #expect(store.all().isEmpty)
        #expect(!FileManager.default.fileExists(atPath: store.wavURL(empty.id).path))
    }

    @Test func finishedRecordingsAreLeftAlone() throws {
        let store = RecordingStore(dir: try temporaryFolder())
        let done = WatchRecording(startedAt: Date(), duration: 0.5)
        try store.save(done)
        let length = synthesizedWAV(samples: 8_000).count
        try synthesizedWAV(samples: 8_000, riffSize: UInt32(length - 8), dataSize: 16_000).write(to: store.wavURL(done.id))

        #expect(store.recover().isEmpty)
        #expect(store.load(done.id) == done)
    }
}
