import Foundation
import NotesKit

/// A conversation's two tracks, the mic and what this Mac played, made into one transcript for its note: the
/// Mac's voices labelled "Mac audio", the mic's copies of the Mac's sound flagged as echoes (kept in the .json,
/// never shown), the mic's speakers numbered again, and the two merged by time.
public enum MacTrackMerge {
    public struct Result: Sendable {
        public var transcript: Transcript
        public var echoes: Int
        public var macWords: Int
        public var gateSeconds: Double
    }

    /// `mic`: the mic track's transcript. `mac`: the Mac's, timed from its own WAV's start, which is `offset`
    /// seconds into the conversation. `micCurve`, `macCurve`: their 10 ms loudness (`Loudness.curve`), each from
    /// its own start; empty skips the loudness gate.
    public static func combine(mic: Transcript, mac: Transcript, offset: Double, micCurve: [Float], macCurve: [Float]) -> Result {
        let (macWords, macTurns) = Tracks.labelMac(mac.words, turns: mac.turns, offset: offset)
        // The Mac's curve placed in conversation time.
        let pad = max(0, Int((offset / Loudness.frameSeconds).rounded()))
        let placed = macCurve.isEmpty ? [] : [Float](repeating: Loudness.floor, count: pad) + macCurve
        let gate = placed.isEmpty || micCurve.isEmpty ? [] : EchoGate.confirmed(mic: micCurve, mac: placed)
        let flags = EchoFilter.echoes(
            mic: mic.words.map { EchoFilter.Timed($0.word, $0.start) },
            mac: macWords.map { EchoFilter.Timed($0.word, $0.start) },
            confirmed: gate)
        var micWords = mic.words
        for i in micWords.indices where flags[i] { micWords[i].echo = true }
        let (renamed, micTurns) = Tracks.renumberMic(micWords, turns: mic.turns)
        let words = Tracks.merge(mic: renamed, mac: macWords)
        var t = mic
        t.words = words
        t.turns = (micTurns + macTurns).sorted { $0.start < $1.start }
        t.text = words.filter(\.shown).map(\.word).joined(separator: " ")
        t.duration = max(mic.duration, offset + mac.duration)
        t.asrSeconds += mac.asrSeconds
        t.diarizationSeconds += mac.diarizationSeconds
        return Result(
            transcript: t, echoes: flags.filter { $0 }.count, macWords: macWords.count,
            gateSeconds: gate.reduce(0) { $0 + ($1.upperBound - $1.lowerBound) })
    }

    /// 10 ms loudness of a 16 kHz mono 16-bit WAV, read a piece at a time. Empty if it can't be read.
    public static func curve(of wav: URL) -> [Float] {
        guard let handle = try? FileHandle(forReadingFrom: wav) else { return [] }
        defer { try? handle.close() }
        guard (try? handle.seek(toOffset: 44)) != nil else { return [] }
        var out: [Float] = []
        var carry: [Float] = []
        let frame = 160
        while let data = try? handle.read(upToCount: 1 << 20), !data.isEmpty {
            var samples = carry
            samples.reserveCapacity(carry.count + data.count / 2)
            data.withUnsafeBytes { raw in
                for at in stride(from: 0, to: raw.count - 1, by: 2) {
                    samples.append(Float(Int16(littleEndian: raw.loadUnaligned(fromByteOffset: at, as: Int16.self))) / 32768)
                }
            }
            let whole = samples.count / frame * frame
            out += Loudness.curve(Array(samples[..<whole]))
            carry = Array(samples[whole...])
        }
        if !carry.isEmpty { out += Loudness.curve(carry) }
        return out
    }
}
