import AVFoundation
import Foundation
import NotesKit

/// A note's kept audio as AAC instead of WAV: 16 kHz mono at about 32 kbps is about 14 MB an hour, not 115. The
/// Processor leaves `<note>.wav` next to the note; this turns it into `<note>.m4a` and deletes the WAV.
nonisolated enum AudioCompressor {
    static let bitRate = 32_000
    /// How far the m4a's length may be from the WAV's before it's not trusted (AAC works in 64 ms packets at 16 kHz).
    static let tolerance = 0.1

    enum Failure: Error, CustomStringConvertible, LogSafeError {
        case lengthMismatch(wav: Double, m4a: Double)

        var description: String {
            switch self {
            case .lengthMismatch(let wav, let m4a): return String(format: "the m4a is %.2f s, the wav %.2f s", m4a, wav)
            }
        }
    }

    /// The audio kept with a note: its .m4a, or a .wav not converted yet. Nil if it has none.
    static func keptAudio(of note: URL) -> URL? {
        let base = note.deletingPathExtension()
        return [base.appendingPathExtension("m4a"), base.appendingPathExtension("wav")]
            .first { FileManager.default.fileExists(atPath: $0.path) }
    }

    /// Converts the note's `.wav` into an `.m4a` beside it, private like the note, checks it's as long, then deletes
    /// the WAV. Returns the m4a, or nil if there was no WAV. Blocking: call it off the main thread.
    @discardableResult
    static func compress(note: URL) throws -> URL? {
        let base = note.deletingPathExtension()
        let wav = base.appendingPathExtension("wav")
        guard FileManager.default.fileExists(atPath: wav.path) else { return nil }
        let m4a = base.appendingPathExtension("m4a")
        try compress(wav: wav, to: m4a)
        return m4a
    }

    static func compress(wav: URL, to m4a: URL) throws {
        let fm = FileManager.default
        // Encoded in the app's temp folder and moved next to the note once checked: a half-written m4a never sits
        // there looking like the note's audio.
        let tmp = fm.temporaryDirectory.appendingPathComponent("sona-\(UUID().uuidString).m4a")
        defer { try? fm.removeItem(at: tmp) }
        let wavSeconds = try encode(wav, to: tmp)
        let m4aSeconds = try duration(of: tmp)
        guard abs(m4aSeconds - wavSeconds) <= tolerance else { throw Failure.lengthMismatch(wav: wavSeconds, m4a: m4aSeconds) }
        chmod(tmp.path, 0o600)
        if fm.fileExists(atPath: m4a.path) { try fm.removeItem(at: m4a) }
        try fm.moveItem(at: tmp, to: m4a)
        chmod(m4a.path, 0o600)
        try fm.removeItem(at: wav)
    }

    /// Seconds of audio in a file AVFoundation can read.
    static func duration(of url: URL) throws -> Double {
        let file = try AVAudioFile(forReading: url)
        return Double(file.length) / file.fileFormat.sampleRate
    }

    /// Encodes `wav` as AAC into `out`, 10 s at a time (an hour never sits in memory). Returns the WAV's length.
    private static func encode(_ wav: URL, to out: URL) throws -> Double {
        let input = try AVAudioFile(forReading: wav)
        let format = input.processingFormat
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: format.sampleRate,
            AVNumberOfChannelsKey: format.channelCount,
            AVEncoderBitRateKey: bitRate,
        ]
        let output = try AVAudioFile(
            forWriting: out, settings: settings, commonFormat: format.commonFormat, interleaved: format.isInterleaved)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(format.sampleRate * 10)) else {
            throw CocoaError(.fileWriteUnknown)
        }
        while input.framePosition < input.length {
            try input.read(into: buffer)
            guard buffer.frameLength > 0 else { break }
            try output.write(from: buffer)
        }
        output.close()  // writes the m4a's header and packet table now, before it's measured
        return Double(input.length) / format.sampleRate
    }

    /// Notes whose `.wav` is still beside them (the app stopped before converting it), as their `.md`.
    static func leftovers(in conversations: URL) -> [URL] {
        let fm = FileManager.default
        var out: [URL] = []
        for day in ((try? fm.contentsOfDirectory(atPath: conversations.path)) ?? []).sorted() where NotesLocation.isDay(day) {
            let dir = conversations.appendingPathComponent(day, isDirectory: true)
            let names = Set((try? fm.contentsOfDirectory(atPath: dir.path)) ?? [])
            for name in names.sorted() where name.hasSuffix(".wav") && !name.hasSuffix(".mac.wav") && !name.hasPrefix(".") {
                let md = String(name.dropLast(4)) + ".md"
                if names.contains(md) { out.append(dir.appendingPathComponent(md)) }
            }
        }
        return out
    }
}
