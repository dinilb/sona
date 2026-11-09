import Foundation
import NotesKit
import SonaEngine
import Testing
@testable import Sona

/// A spool-format WAV (16 kHz mono 16-bit) of a quiet tone, `seconds` long.
func makeSpoolWAV(_ url: URL, seconds: Double) throws {
    let wav = try WavFile(creating: url)
    let n = Int(seconds * 16_000)
    try wav.append((0..<n).map { Float(sin(Double($0) * 2 * .pi * 220 / 16_000) * 0.3) })
    try wav.finish()
}

struct ProcessingAudioTests {
    @Test func keptWAVBecomesAnM4AOfTheSameLength() throws {
        let day = makeTempDir().appendingPathComponent("2026-11-02", isDirectory: true)
        try FileManager.default.createDirectory(at: day, withIntermediateDirectories: true)
        let note = day.appendingPathComponent("14-03 A note.md")
        try Data("note".utf8).write(to: note)
        let wav = day.appendingPathComponent("14-03 A note.wav")
        try makeSpoolWAV(wav, seconds: 3.3)
        #expect(AudioCompressor.leftovers(in: day.deletingLastPathComponent()) == [note])

        let m4a = try #require(try AudioCompressor.compress(note: note))
        #expect(m4a.lastPathComponent == "14-03 A note.m4a")
        #expect(!FileManager.default.fileExists(atPath: wav.path))
        #expect(abs(try AudioCompressor.duration(of: m4a) - 3.3) <= 0.1)
        let mode = try FileManager.default.attributesOfItem(atPath: m4a.path)[.posixPermissions] as? Int
        #expect(mode == 0o600)
        #expect(AudioCompressor.keptAudio(of: note) == m4a)
        #expect(AudioCompressor.leftovers(in: day.deletingLastPathComponent()).isEmpty)
        // Nothing to do the second time.
        #expect(try AudioCompressor.compress(note: note) == nil)
    }

    /// An attempt cut short in the background doesn't count, even if it was the one that moved it to Spool/failed.
    @Test func backgroundAttemptIsGivenBack() throws {
        let spool = Spool(dir: makeTempDir())
        var entry = SpoolEntry(id: "20261102-140300-ABCD", startedAt: Date())
        entry.closed = true
        entry.attempts = 3
        try makeSpoolWAV(spool.wav(entry.id), seconds: 1)
        spool.save(entry)
        spool.fail(entry.id)
        #expect(spool.load(entry.id) == nil)
        #expect(NotesService.isFailed(entry.id, in: spool))

        NotesService.giveBackAttempt(entry.id, to: 2, in: spool)
        #expect(spool.load(entry.id)?.attempts == 2)
        #expect(FileManager.default.fileExists(atPath: spool.wav(entry.id).path))
        #expect(!NotesService.isFailed(entry.id, in: spool))
        #expect(spool.failedCount() == 0)
    }
}
