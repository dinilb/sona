import AVFoundation
import Foundation
import Testing
@testable import SonaWatch

/// ADTS as the watch's AAC recorder writes it: `frames` frames of AAC-LC, 16 kHz mono, each one block (1024 samples,
/// 64 ms) of `frameLength` bytes with a 7-byte header, then `tornBytes` of a last frame cut off by a crash.
func synthesizedADTS(frames: Int, frameLength: Int = 256, tornBytes: Int = 0) -> Data {
    func frame() -> Data {
        var header: [UInt8] = [0xFF, 0xF1, 0x60, 0x40, 0, 0, 0xFC]  // sync, MPEG-4, no CRC; LC, 16 kHz, mono
        header[3] |= UInt8((frameLength >> 11) & 0x03)
        header[4] = UInt8((frameLength >> 3) & 0xFF)
        header[5] = UInt8((frameLength & 0x07) << 5) | 0x1F
        return Data(header) + Data((0..<(frameLength - 7)).map { UInt8(truncatingIfNeeded: $0 &* 13) })
    }
    var data = Data()
    for _ in 0..<frames { data += frame() }
    data += frame().prefix(tornBytes)
    return data
}

struct ADTSFileTests {
    @Test func readsEachFramesHeader() throws {
        let frame = try #require(ADTSFile.frame(in: [UInt8](synthesizedADTS(frames: 1)), at: 0))
        #expect(frame == ADTSFile.Frame(length: 256, samples: 1024, sampleRate: 16_000))
        #expect(ADTSFile.frame(in: [UInt8]("RIFF....WAVE".utf8), at: 0) == nil)
    }

    /// The header AVFoundation writes for a 16 kHz mono `.aac` (MPEG-2 id, no CRC), as seen on a Mac on 7 Nov 2026.
    @Test func readsAVFoundationsOwnHeader() throws {
        let frame = try #require(ADTSFile.frame(in: [0xFF, 0xF9, 0x60, 0x60, 0x01, 0x60, 0x00], at: 0))
        #expect(frame.sampleRate == 16_000)
        #expect(frame.samples == 1024)
    }

    @Test func countsTheFramesInAFile() throws {
        let url = try temporaryFolder().appending(path: "note.aac")
        try synthesizedADTS(frames: 250).write(to: url)  // 250 x 64 ms
        #expect(try ADTSFile.scan(url, repair: false) == 16)
    }

    /// The watch died mid-frame: the whole frames count, and repair cuts the torn one off so the rest decodes.
    @Test func cutsOffATornLastFrame() throws {
        let url = try temporaryFolder().appending(path: "cut.aac")
        try synthesizedADTS(frames: 125, tornBytes: 100).write(to: url)

        #expect(try ADTSFile.scan(url, repair: false) == 8)
        #expect(try Data(contentsOf: url).count == 125 * 256 + 100)  // only looked at

        #expect(try ADTSFile.scan(url, repair: true) == 8)
        #expect(try Data(contentsOf: url).count == 125 * 256)
    }

    /// Damage in the middle isn't a torn last frame: cutting there could throw hours away, so nothing is cut.
    @Test func neverCutsMoreThanAFrame() throws {
        let url = try temporaryFolder().appending(path: "damaged.aac")
        let damaged = synthesizedADTS(frames: 10) + Data(repeating: 0, count: 300) + synthesizedADTS(frames: 100)
        try damaged.write(to: url)

        #expect(try ADTSFile.scan(url, repair: true) == 0.64)  // the frames before the damage
        #expect(try Data(contentsOf: url) == damaged)
    }

    @Test func readsPastAMegabyteAndAnID3Tag() throws {
        let url = try temporaryFolder().appending(path: "long.aac")
        // An ID3v2 tag of 20 bytes in front, then about 1.3 MB of frames: they span reads.
        let tag = Data("ID3".utf8) + Data([4, 0, 0, 0, 0, 0, 10]) + Data(count: 10)
        try (tag + synthesizedADTS(frames: 5_000, frameLength: 261)).write(to: url)
        #expect(try ADTSFile.scan(url, repair: false) == 320)
    }

    @Test func anEmptyFileHoldsNoAudioAndJunkIsNotADTS() throws {
        let folder = try temporaryFolder()
        let empty = folder.appending(path: "empty.aac")
        try Data().write(to: empty)
        #expect(try ADTSFile.scan(empty, repair: true) == 0)
        let junk = folder.appending(path: "junk.aac")
        try Data("not audio at all".utf8).write(to: junk)
        #expect(try ADTSFile.scan(junk, repair: true) == nil)
        #expect(try Data(contentsOf: junk).count == 16)  // junk isn't truncated
    }
}

struct AACRecoveryTests {
    @Test func anAACRecordingThatNeverStoppedIsRepaired() throws {
        let store = RecordingStore(dir: try temporaryFolder())
        let cut = WatchRecording(startedAt: Date(timeIntervalSince1970: 1_000), duration: 0)
        try store.save(cut)
        try synthesizedADTS(frames: 125, tornBytes: 30).write(to: store.aacURL(cut.id))  // 8 s and a torn frame

        #expect(store.recover() == [cut.id])

        #expect(store.load(cut.id)?.duration == 8)
        #expect(store.audioURL(cut.id) == store.aacURL(cut.id))
        #expect(try Data(contentsOf: store.aacURL(cut.id)).count == 125 * 256)
    }

    @Test func anAACWithoutItsJSONGetsOne() throws {
        let store = RecordingStore(dir: try temporaryFolder())
        let id = UUID().uuidString
        try synthesizedADTS(frames: 250).write(to: store.aacURL(id))

        store.recover()

        #expect(store.load(id)?.duration == 16)
        store.delete(id)
        #expect(!FileManager.default.fileExists(atPath: store.aacURL(id).path))
        #expect(store.load(id) == nil)
    }

    /// Only the torn first frame of a recording that died at once: no audio, so nothing is kept.
    @Test func anAACWithNoWholeFrameIsRemoved() throws {
        let store = RecordingStore(dir: try temporaryFolder())
        let empty = WatchRecording(startedAt: Date(), duration: 0)
        try store.save(empty)
        try synthesizedADTS(frames: 0, tornBytes: 5).write(to: store.aacURL(empty.id))

        #expect(store.recover().isEmpty)
        #expect(store.all().isEmpty)
        #expect(!FileManager.default.fileExists(atPath: store.aacURL(empty.id).path))
    }

    /// A WAV from an older build, still waiting on the watch when it updated, is found and sent like before.
    @Test func anOlderBuildsWAVIsStillTheAudio() throws {
        let store = RecordingStore(dir: try temporaryFolder())
        let old = WatchRecording(startedAt: Date(), duration: 2)
        try store.save(old)
        let length = synthesizedWAV(samples: 32_000).count
        try synthesizedWAV(samples: 32_000, riffSize: UInt32(length - 8), dataSize: 64_000).write(to: store.wavURL(old.id))

        #expect(store.recover().isEmpty)
        #expect(store.audioURL(old.id) == store.wavURL(old.id))
        #expect(try store.audioSeconds(old.id, force: false) == 2)
    }
}

@MainActor
struct AACRecordingTests {
    func queue(_ store: RecordingStore, _ session: FakeSession) -> TransferQueue {
        TransferQueue(store: store, session: session, defaults: UserDefaults(suiteName: "sona-tests-\(UUID().uuidString)")!)
    }

    /// The AAC recorder: the length is the frames on disk, and the queue sends the `.aac` as it is.
    @Test func anAACRecordingKeepsItsLengthAndIsSentAsIs() async throws {
        let rig = try Rig()
        rig.mic.aacFrames = 125  // 8 s
        let session = FakeSession()
        let queue = queue(rig.store, session)
        await rig.recorder.start()
        let id = try #require(rig.recorder.currentID)

        rig.recorder.stop()
        queue.run()

        #expect(rig.store.load(id)?.duration == 8)
        #expect(rig.store.audioURL(id).pathExtension == "aac")
        #expect(session.sent == [id])
    }

    /// The fallback: the recorder wrote a WAV beside the `.aac` it was asked for, and that's what's kept and sent.
    @Test func theWAVFallbackIsKeptAndSent() async throws {
        let rig = try Rig()
        let session = FakeSession()
        let queue = queue(rig.store, session)
        await rig.recorder.start()
        let id = try #require(rig.recorder.currentID)

        rig.recorder.stop()
        queue.run()

        #expect(rig.store.load(id)?.duration == 2)
        #expect(rig.store.audioURL(id) == rig.store.wavURL(id))
        #expect(!FileManager.default.fileExists(atPath: rig.store.aacURL(id).path))
        #expect(session.sent == [id])
    }

    /// The audio daemon restarted mid-frame: the orphaned recorder never finished its file, so the torn frame is cut.
    @Test func aMediaServicesResetCutsTheTornFrame() async throws {
        let rig = try Rig()
        rig.mic.aacFrames = 125
        await rig.recorder.start()
        let id = try #require(rig.recorder.currentID)
        let handle = try FileHandle(forWritingTo: rig.store.aacURL(id))
        try handle.seekToEnd()
        try handle.write(contentsOf: synthesizedADTS(frames: 0, tornBytes: 40))
        try handle.close()

        rig.center.post(name: AVAudioSession.mediaServicesWereResetNotification, object: nil)

        #expect(await waitUntil { !rig.recorder.isRecording })
        #expect(rig.store.load(id)?.duration == 8)
        #expect(try Data(contentsOf: rig.store.aacURL(id)).count == 125 * 256)
    }

    /// An AAC stranded at 0 (its final save failed) is repaired by the queue and sent, without waiting for a relaunch.
    @Test func aStrandedAACIsRepairedAndSent() throws {
        let store = RecordingStore(dir: try temporaryFolder())
        let session = FakeSession()
        let queue = queue(store, session)
        let stranded = WatchRecording(startedAt: Date(), duration: 0)
        try store.save(stranded)
        try synthesizedADTS(frames: 125, tornBytes: 10).write(to: store.aacURL(stranded.id))

        queue.run()

        #expect(store.load(stranded.id)?.duration == 8)
        #expect(session.sent == [stranded.id])
    }
}
