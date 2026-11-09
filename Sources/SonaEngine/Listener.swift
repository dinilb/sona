import FluidAudio
import Foundation
import NotesKit

/// The always-on conversation logic, shared by the app (mic) and `sona simulate` (a file fed through
/// at full speed). Silero VAD runs on every 256 ms chunk loud enough to be speech (a quiet room skips it). The
/// first speech opens a conversation (with 1 s of audio from before it); `quietSeconds` without speech closes it.
/// Every sample of an open conversation is appended to a WAV in the spool as it arrives, so nothing is only in
/// memory.
///
/// Time comes from the samples, not the wall clock, so the simulation behaves exactly like the mic.
/// Started from an earlier prototype (parakeet-always-on-note, Listener.swift).
public final class Listener {
    public struct Config: Sendable {
        public var quietSeconds: Double
        public var vadThreshold: Float = 0.6
        public var preRollSeconds = 1.0
        /// Conversations with less speech than this are dropped (a cough, a door).
        public var minSpeechSeconds = 1.5
        /// Past this length a conversation is split at the next real pause (`splitPause`), so a TV or a
        /// podcast playing all evening becomes hour-long notes, not one 4-hour one (which also needs ~2 GB
        /// to transcribe). Real talk this long gets split too, at a pause, which costs little.
        public var splitAfterSeconds: Double = 3600
        public var splitPause = 2.0
        /// No pause that long by this length: split right here, mid-speech.
        public var maxSeconds: Double = 4500

        public init(quietSeconds: Double) { self.quietSeconds = quietSeconds }
    }

    public enum Event: Sendable {
        /// Speech started or stopped (for the menu bar icon).
        case speech(Bool)
        case opened(Date)
        /// A finished conversation, ready to transcribe.
        case closed(SpoolEntry)
        /// Closed with too little speech; its audio is already deleted.
        case discarded(String)
    }

    public var config: Config
    /// Longest gap in the audio filled with silence; a longer one ends the conversation.
    static let maxGapFill = 60.0
    public var onEvent: (Event) -> Void = { _ in }
    public var conversationStartedAt: Date? { open?.entry.startedAt }
    /// The spool entry being recorded into (also `spool.openID`, which `Processor.recover` skips).
    public var openEntryID: String? { open?.entry.id }
    /// Is this Mac playing audio? Sampled about once a second while a conversation is open (the app passes
    /// `Playback.sample`; nil in `simulate`, where a file can't tell).
    public var playbackProbe: (() -> Playback.Sample)?

    private let vad: VadManager
    private let spool: Spool
    private let rate = 16_000
    private let chunk = VadManager.chunkSize  // 4096 samples = 256 ms
    private var vadState: VadStreamState
    private var buffer: [Float] = []
    private var bufferTime: Date?
    private var preRoll: [Float] = []
    private var speaking = false
    private var nextExpected: Date?
    /// What this Mac played, sample-aligned with `buffer` (nil while it plays nothing): its own voice detector,
    /// its own WAV. Speech on either track opens a conversation and keeps it open.
    private var macBuffer: [Float]?
    /// The Mac stopped: `macBuffer` goes once what's in it has been handled.
    private var macEnding = false
    private var macVadState: VadStreamState
    /// The end of `preRoll` that the Mac played too (aligned to its end; shorter if the Mac started later).
    private var macPreRoll: [Float] = []
    /// Below this RMS (about -50 dBFS, the live voice gate's floor too) a chunk of either track counts as silent
    /// without running the voice detector: speech, even across a room, is louder.
    static let floor: Float = 0.003
    /// A voice detector's memory with nothing heard, for a track whose chunk was too quiet to run it on.
    private let freshVadState: VadStreamState

    static func rms(_ x: [Float]) -> Float {
        var sum: Float = 0
        for v in x { sum += v * v }
        return (sum / Float(max(x.count, 1))).squareRoot()
    }

    private final class Open {
        var entry: SpoolEntry
        let file: WavFile
        var lastSpeechEnd = 0  // samples
        var speechSamples = 0
        var checkpointAt = 0  // samples
        var playback = Playback.Tally()
        var lastSample: Playback.Sample?
        var chunks = 0
        var syncs = 0, syncSeconds = 0.0, syncMax = 0.0  // checkpoint cost, logged at close
        /// The Mac's audio, from `entry.mac.offset` on.
        var macFile: WavFile?
        var macSpeechSamples = 0
        init(entry: SpoolEntry, file: WavFile) {
            self.entry = entry
            self.file = file
        }
    }
    private var open: Open?

    public init(vad: VadManager, spool: Spool, config: Config) async {
        self.vad = vad
        self.spool = spool
        self.config = config
        let fresh = await vad.makeStreamState()
        freshVadState = fresh
        vadState = fresh
        macVadState = fresh
    }

    /// Feed captured audio (16 kHz mono) starting at `time`. A short gap since the last call (an engine
    /// restart) is filled with silence so timestamps stay true; a gap longer than the quiet time or a minute
    /// ends the conversation (audio after it starts a new one, so no timestamp is ever shifted).
    /// `mac`: what this Mac played over the same moment, as many samples (nil: it played nothing).
    public func feed(_ samples: [Float], mac: [Float]? = nil, at time: Date) async throws {
        if let expected = nextExpected {
            let gap = time.timeIntervalSince(expected)
            if gap > min(config.quietSeconds, Self.maxGapFill) {
                try close(reason: "gap in audio of \(Int(gap)) s")
                buffer = []
                bufferTime = nil
                macBuffer = nil
            } else if gap > 0.5 {
                let fill = [Float](repeating: 0, count: Int(gap * Double(rate)))
                try await process(fill, mac: macBuffer == nil ? nil : fill)
            }
        }
        if bufferTime == nil { bufferTime = time }
        nextExpected = time.addingTimeInterval(Double(samples.count) / Double(rate))
        try await process(samples, mac: mac.map { $0.count == samples.count ? $0 : Self.fit($0, samples.count) })
    }

    static func fit(_ x: [Float], _ n: Int) -> [Float] { x.count >= n ? Array(x.prefix(n)) : x + [Float](repeating: 0, count: n - x.count) }

    private func process(_ samples: [Float], mac: [Float]?) async throws {
        if let mac {
            if macBuffer == nil { macBuffer = [Float](repeating: 0, count: buffer.count) }
            macBuffer!.append(contentsOf: mac)
            macEnding = false
        } else if macBuffer != nil {
            macBuffer!.append(contentsOf: repeatElement(0, count: samples.count))
            macEnding = true
        }
        buffer.append(contentsOf: samples)
        while buffer.count >= chunk {
            let piece = Array(buffer.prefix(chunk))
            buffer.removeFirst(chunk)
            var macPiece: [Float]?
            if macBuffer != nil {
                macPiece = Array(macBuffer!.prefix(chunk))
                macBuffer!.removeFirst(chunk)
                if macEnding, macBuffer!.isEmpty || !macBuffer!.contains(where: { $0 != 0 }) {
                    macBuffer = nil
                    macEnding = false
                }
            }
            let pieceTime = bufferTime ?? Date()
            bufferTime = pieceTime.addingTimeInterval(Double(chunk) / Double(rate))
            try await handle(piece, mac: macPiece, at: pieceTime)
        }
    }

    /// Is the Mac's piece speech? Its own voice detector; a quiet piece is no without it (and its memory starts over).
    private func macSpeech(_ piece: [Float]) async throws -> Bool {
        guard Self.rms(piece) >= Self.floor else {
            macVadState = freshVadState
            return false
        }
        let result = try await vad.processStreamingChunk(piece, state: macVadState)
        macVadState = result.state
        return result.probability >= config.vadThreshold
    }

    /// Is the mic's piece speech? Like the Mac's: a quiet room never wakes the voice detector.
    private func micSpeech(_ piece: [Float]) async throws -> Bool {
        guard Self.rms(piece) >= Self.floor else {
            vadState = freshVadState
            return false
        }
        let result = try await vad.processStreamingChunk(piece, state: vadState)
        vadState = result.state
        return result.probability >= config.vadThreshold
    }

    private func handle(_ piece: [Float], mac macPiece: [Float]?, at time: Date) async throws {
        let micSpeaking = try await micSpeech(piece)
        var macSpeaking = false
        if let macPiece { macSpeaking = try await macSpeech(macPiece) }
        let isSpeech = micSpeaking || macSpeaking
        if isSpeech != speaking {
            speaking = isSpeech
            onEvent(.speech(isSpeech))
        }

        guard let c = open else {
            preRoll.append(contentsOf: piece)
            let keep = Int(config.preRollSeconds * Double(rate))
            if preRoll.count > keep { preRoll.removeFirst(preRoll.count - keep) }
            if let macPiece { macPreRoll.append(contentsOf: macPiece) } else { macPreRoll = [] }
            if macPreRoll.count > preRoll.count { macPreRoll.removeFirst(macPreRoll.count - preRoll.count) }
            guard isSpeech else { return }
            let started = time.addingTimeInterval(-Double(preRoll.count - piece.count) / Double(rate))
            let entry = SpoolEntry(id: Spool.newID(for: started), startedAt: started)
            spool.openID = entry.id  // before the WAV exists, so a recover can never pick it up
            let c: Open
            do { c = Open(entry: entry, file: try WavFile(creating: spool.wav(entry.id))) } catch {
                spool.openID = nil
                throw error
            }
            spool.save(entry)
            do { try c.file.append(preRoll) } catch {
                // Nothing worth keeping yet: drop it rather than leave an open entry the retry won't pick up.
                spool.openID = nil
                spool.remove(entry.id)
                throw error
            }
            c.lastSpeechEnd = c.file.samples
            c.speechSamples = piece.count
            if !macPreRoll.isEmpty {
                do { try appendMac(macPreRoll, to: c, at: preRoll.count - macPreRoll.count) } catch {
                    Log.note("couldn't start the Mac audio WAV: \(Log.describe(error))")
                }
                if macSpeaking { c.macSpeechSamples = piece.count }
            }
            preRoll = []
            macPreRoll = []
            open = c
            Log.note("conversation \(Log.ref(started)) started")
            onEvent(.opened(started))
            return
        }

        let at = c.file.samples
        try c.file.append(piece)
        if let macPiece {
            do { try appendMac(macPiece, to: c, at: at) } catch {
                if c.macFile == nil || c.syncs == 0 { Log.note("couldn't write the Mac audio: \(Log.describe(error))") }
            }
        }
        if let probe = playbackProbe, c.chunks % 4 == 0 { c.lastSample = probe() }  // ~1 s
        c.chunks += 1
        if isSpeech {
            c.lastSpeechEnd = c.file.samples
            c.speechSamples += piece.count
            // The Mac speaking counts as the Mac playing (a call excepted, as ever); with a Mac track, all speech is
            // counted even without a probe.
            var sample = c.lastSample ?? (c.macFile != nil ? Playback.Sample(playing: false, call: false) : nil)
            if macSpeaking {
                c.macSpeechSamples += piece.count
                sample?.playing = true
            }
            c.playback.add(speechWith: sample)
        }

        // Checkpoint every 5 s, durably: a crash or power cut loses at most the last 5 s.
        if c.file.samples - c.checkpointAt >= 5 * rate {
            c.checkpointAt = c.file.samples
            c.entry.speechEnd = Double(c.lastSpeechEnd) / Double(rate)
            c.entry.speechSeconds = Double(c.speechSamples) / Double(rate)
            c.entry.playback = c.playback.fraction
            c.entry.mac?.speechSeconds = Double(c.macSpeechSamples) / Double(rate)
            let t0 = Date()
            spool.save(c.entry, durable: true)
            do { try c.file.checkpoint() } catch { if c.syncs == 0 { Log.note("checkpoint sync failed: \(Log.describe(error))") } }
            try? c.macFile?.checkpoint()
            let took = Date().timeIntervalSince(t0)
            c.syncs += 1
            c.syncSeconds += took
            c.syncMax = max(c.syncMax, took)
        }

        let quiet = Double(c.file.samples - c.lastSpeechEnd) / Double(rate)
        let length = Double(c.file.samples) / Double(rate)
        if quiet >= config.quietSeconds {
            try close(reason: "quiet for \(fmt(quiet, 0)) s")
        } else if length >= config.splitAfterSeconds, quiet >= config.splitPause {
            try close(reason: "split at a pause after \(fmt(length / 60, 0)) min")
        } else if length >= config.maxSeconds {
            try close(reason: "reached the maximum length")
        }
    }

    /// Ends the open conversation now (quiet, pause, sleep, quit). Keeps 1 s after the last speech. `cut`: and
    /// keeps nothing from then on ("delete the last N minutes"); if that leaves too little, it's dropped.
    public func close(reason: String, cut: Date? = nil) throws {
        guard let c = open else { return }
        open = nil
        preRoll = []
        if speaking {
            speaking = false
            onEvent(.speech(false))
        }
        var end = min(Double(c.file.samples), Double(c.lastSpeechEnd + rate)) / Double(rate)
        var speech = Double(c.speechSamples) / Double(rate)
        if let cut {
            end = min(end, max(0, cut.timeIntervalSince(c.entry.startedAt)))
            speech = min(speech, end)  // at most what's left
        }
        do {
            try c.file.finish(truncatingTo: end)
        } catch {
            // Still hand it over: the processor repairs the header. Never strand a conversation.
            Log.note("couldn't finish the conversation WAV cleanly: \(Log.describe(error))")
        }
        if let mac = c.macFile, let offset = c.entry.mac?.offset {
            do { try mac.finish(truncatingTo: max(0, end - offset)) } catch { Log.note("couldn't finish the Mac audio WAV cleanly: \(Log.describe(error))") }
            c.entry.mac?.speechSeconds = min(Double(c.macSpeechSamples) / Double(rate), speech)
        }
        c.entry.speechEnd = end
        c.entry.speechSeconds = speech
        c.entry.playback = c.playback.fraction
        c.entry.closed = true

        if c.entry.speechSeconds < config.minSpeechSeconds {
            spool.remove(c.entry.id)
            spool.openID = nil
            Log.note("conversation \(Log.ref(c.entry.startedAt)) dropped (\(reason)): only \(fmt(c.entry.speechSeconds, 1)) s of speech")
            onEvent(.discarded(c.entry.id))
            return
        }
        spool.save(c.entry, durable: true)
        spool.openID = nil  // only now that it's saved as closed: the processor may take it from here
        let sync = c.syncs == 0 ? "" : String(
            format: ", %d checkpoints avg %.1f ms max %.1f ms", c.syncs, c.syncSeconds / Double(c.syncs) * 1000, c.syncMax * 1000)
        Log.note("conversation \(Log.ref(c.entry.startedAt)) closed (\(reason)): \(fmt(end, 1)) s of audio, \(fmt(c.entry.speechSeconds, 1)) s of speech\(sync)\(c.entry.playback.map { String(format: ", Mac playing audio %.0f%% of it", $0 * 100) } ?? "")")
        onEvent(.closed(c.entry))
    }

    /// After a pause or sleep: forget the room's recent state and the time continuity.
    public func reset() async {
        try? close(reason: "reset")
        await forgetRecent()
    }

    /// "Delete the last N minutes": the open conversation ends at `cut` (dropped if it started after it), and the
    /// audio held for the next one's start is forgotten.
    public func forget(from cut: Date) async throws {
        await forgetRecent()
        try close(reason: "deleted the last minutes", cut: cut)
    }

    private func forgetRecent() async {
        buffer = []
        bufferTime = nil
        nextExpected = nil
        preRoll = []
        macBuffer = nil
        macEnding = false
        macPreRoll = []
        vadState = await vad.makeStreamState()
        macVadState = await vad.makeStreamState()
    }

    /// Writes the Mac's `samples` that go with the conversation's mic samples from `at` on: its WAV is made the first
    /// time (its start saved with the entry first, so a crash still knows where it goes), and a gap since the Mac
    /// last played is filled with silence, keeping the two sample-aligned.
    private func appendMac(_ samples: [Float], to c: Open, at: Int) throws {
        if c.macFile == nil {
            c.entry.mac = SpoolEntry.MacTrack(offset: Double(max(at, 0)) / Double(rate))
            spool.save(c.entry)
            c.macFile = try WavFile(creating: spool.macWav(c.entry.id))
            Log.note("conversation \(Log.ref(c.entry.startedAt)): this Mac's audio too, from \(fmt(Double(max(at, 0)) / Double(rate), 1)) s")
        }
        guard let file = c.macFile, let offset = c.entry.mac?.offset else { return }
        let behind = at - Int((offset * Double(rate)).rounded()) - file.samples
        if behind > 0 { try file.append([Float](repeating: 0, count: behind)) }
        try file.append(samples)
    }
}
