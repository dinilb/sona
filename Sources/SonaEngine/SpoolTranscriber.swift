import FluidAudio
import Foundation
import NotesKit

/// Audio still in the spool (the conversation being recorded, or one waiting for its note), transcribed on demand for
/// the MCP server through `sona spool-serve`. The notes pipeline (Parakeet, then the offline diarizer), a few minutes
/// at a time: each finished piece is kept in memory, so asking again only transcribes the audio that's new since.
///
/// Read-only: it never writes, repairs, cuts or deletes anything in the spool, and never writes a note or any other
/// file. Nothing it heard is logged. A piece is only reused while the file still holds the same audio there ("delete
/// the last N minutes" cuts the file: the cut piece is dropped and never shown again).
public actor SpoolTranscriber {
    /// Pieces end near every this many seconds of a track, at its quietest moment within `searchSeconds`.
    public static let pieceSeconds = 300.0
    static let searchSeconds = 10.0
    static let rate = 16_000
    /// 100 ms: the unit quiet is measured in, and every piece boundary is a multiple of it.
    static let frame = 1_600

    let spool: Spool
    let model: String
    private var engine: Engine?
    /// Tests only: stands in for the models (samples to words with "Speaker N" names, and their voices).
    private var stand: (@Sendable ([Float]) async throws -> Voiced)?
    private var pieces: [PieceKey: Piece] = [:]
    /// Piece boundaries per track file, computed once (they never move as the file grows).
    private var cuts: [TrackKey: [Int]] = [:]
    /// What the last request didn't get to before its time ran out, done between requests (`continueLeftover`).
    private var leftover: [Job] = []

    public init(spool: Spool, model: String) {
        self.spool = spool
        self.model = model
    }

    func useStandIn(_ f: @escaping @Sendable ([Float]) async throws -> Voiced) { stand = f }

    /// What a piece came to: words timed from the piece's start, each speaker's voice, and its loudness curve (for the
    /// Mac's echo filter, `MacTrackMerge`).
    public struct Voiced: Sendable {
        public var words: [Word]
        public var voices: [String: [Float]]

        public init(words: [Word], voices: [String: [Float]]) {
            self.words = words
            self.voices = voices
        }
    }

    struct TrackKey: Hashable {
        var path: String
        var inode: UInt64
    }

    struct PieceKey: Hashable {
        var track: TrackKey
        var start: Int
        var end: Int
    }

    struct Piece {
        var voiced: Voiced
        var curve: [Float]
        /// The audio it was made from, to tell it's still there (`fingerprint`).
        var print: Int
    }

    struct Job: Hashable {
        var track: Track
        var start: Int
        var end: Int
    }

    /// One track of a recording, read by sample ranges. Its length comes from the file's size: the header's sizes say
    /// 0 while it's being recorded.
    struct Track: Hashable {
        let url: URL
        let key: TrackKey
        let count: Int
        /// Where it starts in the recording, in seconds (the Mac's track can start later).
        let offset: Double

        init?(url: URL, offset: Double) {
            var st = stat()
            guard lstat(url.path, &st) == 0, (st.st_mode & S_IFMT) == S_IFREG else { return nil }
            self.url = url
            key = TrackKey(path: url.path, inode: UInt64(st.st_ino))
            count = max(0, Int(st.st_size) - 44) / 2
            self.offset = offset
        }

        /// Samples `range` as floats, or nil if the file can't be read (or is shorter now).
        func samples(_ range: Range<Int>) -> [Float]? {
            guard let bytes = bytes(range) else { return nil }
            return bytes.withUnsafeBytes { raw in
                (0..<(raw.count / 2)).map { Float(Int16(littleEndian: raw.loadUnaligned(fromByteOffset: $0 * 2, as: Int16.self))) / 32768 }
            }
        }

        func bytes(_ range: Range<Int>) -> Data? {
            guard range.lowerBound >= 0, let handle = try? FileHandle(forReadingFrom: url) else { return nil }
            defer { try? handle.close() }
            guard (try? handle.seek(toOffset: UInt64(44 + range.lowerBound * 2))) != nil,
                let data = try? handle.read(upToCount: range.count * 2), data.count == range.count * 2
            else { return nil }
            return data
        }
    }

    // MARK: requests

    /// Words said `from..<to` seconds into recording `id`, transcribing what isn't yet, newest first, until `deadline`.
    /// What's left is done between requests (`continueLeftover`), so asking again soon gets more.
    public func slice(id: String, from: Double, to: Double, deadline: Date) async -> SpoolSlice {
        guard let entry = spool.load(id), let mic = Track(url: spool.wav(id), offset: 0) else {
            return SpoolSlice(words: [], from: from, to: to, doneFrom: to, duration: 0, error: "That recording isn't in the spool any more (it's a note now, or was deleted).")
        }
        prune()
        let duration = Double(mic.count) / Double(Self.rate)
        let to = min(max(to, 0), duration)
        let from = min(max(from, 0), to)
        var tracks = [mic]
        if let offset = entry.mac?.offset, let mac = Track(url: spool.macWav(id), offset: offset), mac.count > 0 { tracks.append(mac) }

        // The pieces of each track that overlap the stretch, newest first across both tracks.
        var jobs: [Job] = []
        for track in tracks {
            let edges = boundaries(track)
            for (a, b) in zip(edges, edges.dropFirst()) {
                let start = track.offset + Double(a) / Double(Self.rate), end = track.offset + Double(b) / Double(Self.rate)
                if end > from, start < to { jobs.append(Job(track: track, start: a, end: b)) }
            }
        }
        jobs.sort { ($0.track.offset + Double($0.end) / Double(Self.rate)) > ($1.track.offset + Double($1.end) / Double(Self.rate)) }
        leftover.removeAll { job in jobs.contains(job) }

        var done: [Job: Piece] = [:]
        var heard = Set<TrackKey>()
        var later: [Job] = []
        for job in jobs {
            if let piece = cached(job) {
                done[job] = piece
                continue
            }
            // At least the newest piece of each track a request, so asking again always gets further.
            guard Date() < deadline || !heard.contains(job.track.key) else {
                later.append(job)
                continue
            }
            heard.insert(job.track.key)
            do {
                done[job] = try await transcribe(job)
            } catch {
                // No models, or the file went: say why, with whatever was done.
                leftover = []
                if let engineError = error as? EngineError { return SpoolSlice(words: [], from: from, to: to, doneFrom: to, duration: duration, error: engineError.description) }
                Log.note("spool transcriber: a piece couldn't be transcribed: \(Log.describe(error))")
                return SpoolSlice(words: [], from: from, to: to, doneFrom: to, duration: duration, error: "Its audio couldn't be transcribed just now.")
            }
        }

        leftover = later + leftover

        // Covered back from `to` as far as every track's newest pieces are done without a gap.
        var doneFrom = from
        for track in tracks {
            let mine = jobs.filter { $0.track == track }  // newest first
            // All done: covered from `from` (a track that starts later has nothing before its start).
            var reach = from
            for job in mine where done[job] == nil {
                reach = track.offset + Double(job.end) / Double(Self.rate)
                break
            }
            doneFrom = max(doneFrom, min(reach, to))
        }

        let words = merge(tracks: tracks, done: done, from: max(from, doneFrom), to: to)
        return SpoolSlice(words: words, from: from, to: to, doneFrom: max(from, doneFrom), duration: duration)
    }

    /// Transcribes one piece the last request ran out of time for. False when there's nothing left to do.
    public func continueLeftover() async -> Bool {
        while let job = leftover.first {
            leftover.removeFirst()
            guard Track(url: job.track.url, offset: job.track.offset)?.key == job.track.key, cached(job) == nil else { continue }
            _ = try? await transcribe(job)
            return true
        }
        return false
    }

    public var hasLeftover: Bool { !leftover.isEmpty }

    /// Lets the models go (about 500 MB); what was transcribed stays. The next piece loads them again (well under a
    /// second once they've been loaded before).
    public func unloadEngine() { engine = nil }

    public var engineLoaded: Bool { engine != nil }

    // MARK: pieces

    /// Where each track's pieces start and end, in samples: 0, then near every `pieceSeconds` at the quietest 100 ms
    /// within `searchSeconds` (once there's that much audio after it), then the end of the audio so far.
    func boundaries(_ track: Track) -> [Int] {
        var edges = cuts[track.key] ?? [0]
        if let last = edges.last, last > track.count { edges = [0] }  // cut shorter since ("delete the last N minutes")
        let piece = Int(Self.pieceSeconds) * Self.rate, search = Int(Self.searchSeconds) * Self.rate
        var mark = (edges.count) * piece
        while mark + search <= track.count {
            guard let around = track.samples((mark - search)..<(mark + search)) else { break }
            edges.append(mark - search + Self.quietest(around))
            mark += piece
        }
        cuts[track.key] = edges
        return edges.last == track.count ? edges : edges + [track.count]
    }

    /// The start of the quietest 100 ms frame in `samples` (a multiple of `frame`).
    static func quietest(_ samples: [Float]) -> Int {
        var best = 0
        var lowest = Float.infinity
        var at = 0
        while at + frame <= samples.count {
            var sum: Float = 0
            for i in at..<(at + frame) { sum += samples[i] * samples[i] }
            if sum < lowest {
                lowest = sum
                best = at
            }
            at += frame
        }
        return best
    }

    /// A piece already transcribed, if the file still holds the same audio there.
    func cached(_ job: Job) -> Piece? {
        let key = PieceKey(track: job.track.key, start: job.start, end: job.end)
        guard let piece = pieces[key] else { return nil }
        guard job.end <= job.track.count, Self.fingerprint(job.track, job.start..<job.end) == piece.print else {
            pieces[key] = nil
            return nil
        }
        return piece
    }

    /// A cheap check the audio there hasn't changed: a hash of its first and last 32 KB. The file only ever grows, or
    /// is cut ("delete the last N minutes"), or replaced (a new inode).
    static func fingerprint(_ track: Track, _ range: Range<Int>) -> Int? {
        let edge = min(16_384, range.count)
        guard let head = track.bytes(range.lowerBound..<(range.lowerBound + edge)),
            let tail = track.bytes((range.upperBound - edge)..<range.upperBound)
        else { return nil }
        var hasher = Hasher()
        hasher.combine(head)
        hasher.combine(tail)
        return hasher.finalize()
    }

    func transcribe(_ job: Job) async throws -> Piece {
        guard let samples = job.track.samples(job.start..<job.end), let print = Self.fingerprint(job.track, job.start..<job.end) else {
            throw CocoaError(.fileReadUnknown)
        }
        let curve = Loudness.curve(samples)
        var voiced = Voiced(words: [], voices: [:])
        // Quiet all through (the Mac's track is silence while it plays nothing): nothing to hear, so no model runs.
        if samples.contains(where: { abs($0) >= Listener.floor }) {
            if let stand {
                voiced = try await stand(samples)
            } else {
                voiced = try await loadEngine().voiced(samples: samples)
            }
        }
        let piece = Piece(voiced: voiced, curve: curve, print: print)
        let key = PieceKey(track: job.track.key, start: job.start, end: job.end)
        // The same start with another end was the last piece before the file grew: this one replaces it.
        pieces = pieces.filter { $0.key.track != key.track || $0.key.start != key.start }
        pieces[key] = piece
        return piece
    }

    func loadEngine() async throws -> Engine {
        if let engine { return engine }
        let loaded = try await Engine.load(model: model)
        engine = loaded
        return loaded
    }

    /// Forgets pieces of files that are gone (the note was written, or the recording deleted) or cut short since.
    func prune() {
        var counts: [TrackKey: Int] = [:]
        for key in Set(pieces.keys.map(\.track)) {
            if let now = Track(url: URL(fileURLWithPath: key.path), offset: 0), now.key == key { counts[key] = now.count }
        }
        pieces = pieces.filter { piece in counts[piece.key.track].map { piece.key.end <= $0 } ?? false }
        cuts = cuts.filter { counts[$0.key] != nil }
        leftover.removeAll { job in counts[job.track.key].map { job.end > $0 } ?? false }
    }

    // MARK: one transcript

    /// The done pieces of every track as one transcript, `from..<to` seconds into the recording: each track's pieces
    /// joined (speakers matched by voice, `SpeakerLink`), then the Mac's track merged in with its echoes flagged, as
    /// a note's are (`MacTrackMerge`).
    func merge(tracks: [Track], done: [Job: Piece], from: Double, to: Double) -> [Word] {
        guard from < to else { return [] }
        var joined: [(track: Track, words: [Word], curve: [Float], start: Double)] = []
        for track in tracks {
            // This track's done pieces in time order that reach into from..<to, as one run.
            let mine = done.filter { $0.key.track == track }.sorted { $0.key.start < $1.key.start }
                .filter { track.offset + Double($0.key.end) / Double(Self.rate) > from && track.offset + Double($0.key.start) / Double(Self.rate) < to }
            guard let first = mine.first else { continue }
            let link = SpeakerLink.link(mine.map { done in
                let at = Double(done.key.start - first.key.start) / Double(Self.rate)
                return SpeakerLink.Piece(
                    words: done.value.voiced.words.map { w in
                        var w = w
                        w.start += at
                        w.end += at
                        return w
                    },
                    voices: done.value.voiced.voices)
            })
            joined.append((track, link, mine.flatMap(\.value.curve), track.offset + Double(first.key.start) / Double(Self.rate)))
        }
        guard let mic = joined.first(where: { $0.track.offset == 0 && !$0.track.url.lastPathComponent.hasSuffix(".mac.wav") }) else {
            return []
        }
        var words: [Word]
        if let mac = joined.first(where: { $0.track.url.lastPathComponent.hasSuffix(".mac.wav") }) {
            // On the mic run's clock: the Mac's run starts `offset` into it (dropped before the mic's run starts).
            var macWords = mac.words
            var macCurve = mac.curve
            var offset = mac.start - mic.start
            if offset < 0 {
                macWords = macWords.filter { $0.start >= -offset }.map { w in
                    var w = w
                    w.start += offset
                    w.end += offset
                    return w
                }
                macCurve = Array(macCurve.dropFirst(Int((-offset / Loudness.frameSeconds).rounded())))
                offset = 0
            }
            let t = { (w: [Word]) in Transcript(startedAt: Date(), duration: 0, text: "", words: w, turns: [], asrSeconds: 0, diarizationSeconds: 0, model: "") }
            words = MacTrackMerge.combine(mic: t(mic.words), mac: t(macWords), offset: offset, micCurve: mic.curve, macCurve: macCurve).transcript.words
        } else {
            words = Tracks.renumberMic(mic.words, turns: []).0
        }
        let kept = words.compactMap { w in
            var w = w
            w.start += mic.start
            w.end += mic.start
            return w.start >= from && w.start < to ? w : nil
        }
        return Self.renumberRoom(kept)
    }

    /// The room's speakers numbered again by first appearance among the words shown, so a stretch whose first
    /// speaker was the recording's second still starts at Speaker 1. The Mac's keep their labels.
    static func renumberRoom(_ words: [Word]) -> [Word] {
        var order: [String] = []
        for w in words where w.track == nil && w.shown && !order.contains(w.speaker) { order.append(w.speaker) }
        for w in words where w.track == nil && !order.contains(w.speaker) { order.append(w.speaker) }
        return words.map { w in
            guard w.track == nil, let i = order.firstIndex(of: w.speaker) else { return w }
            var w = w
            w.speaker = "Speaker \(i + 1)"
            return w
        }
    }
}

extension Engine {
    /// Samples already in memory (16 kHz mono) through the notes pipeline, with each speaker's voice (the diarizer's
    /// embedding for them, unit length), so pieces transcribed apart can be joined (`SpeakerLink`). Short audio is
    /// padded with quiet to the model's 1 s minimum.
    func voiced(samples: [Float]) async throws -> SpoolTranscriber.Voiced {
        var audio = samples
        if audio.count < 16_000 { audio += [Float](repeating: 0, count: 16_000 - audio.count) }
        var state = TdtDecoderState.make(decoderLayers: decoderLayers)
        let result = try await asr.transcribe(audio, decoderState: &state)
        var diarization: DiarizationResult?
        do {
            diarization = try await diarizer.process(audio: audio)
        } catch OfflineDiarizationError.noSpeechDetected {
            diarization = nil
        }
        let raw = buildWordTimings(from: result.tokenTimings ?? [])
        let segments = (diarization?.segments ?? []).sorted { $0.startTimeSeconds < $1.startTimeSeconds }
        let words = segments.isEmpty ? Merge.oneSpeaker(raw).0 : Merge.assignSpeakers(words: raw, segments: segments).0
        var voices: [String: [Float]] = [:]
        for (id, name) in Merge.speakerNames(segments) {
            // The diarizer's own per-speaker embedding, else the mean of its segments' weighted by length.
            var voice = diarization?.speakerDatabase?[id] ?? []
            if voice.isEmpty {
                for s in segments where s.speakerId == id && !s.embedding.isEmpty {
                    if voice.isEmpty { voice = [Float](repeating: 0, count: s.embedding.count) }
                    guard voice.count == s.embedding.count else { continue }
                    for i in voice.indices { voice[i] += s.embedding[i] * s.durationSeconds }
                }
            }
            if !voice.isEmpty { voices[name] = SpeakerLink.unit(voice) }
        }
        return SpoolTranscriber.Voiced(words: words, voices: voices)
    }
}
