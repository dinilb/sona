import Foundation
import NotesKit

/// Turns closed conversations in the spool into notes, one at a time. The audio is only deleted after its
/// note is on disk. A conversation that fails is retried on the next launch, and after 3 failures it's moved
/// to Spool/failed with its audio kept, and the menu says so. Nothing is ever dropped silently.
public actor Processor {
    public struct State: Sendable, Equatable {
        public var pending = 0
        public var busy = false
        public var lastNote: URL?
        public var lastError: String?
        public var failed = 0

        public init() {}
    }

    /// Hook for an optional local summary later (a local LLM, say). v1 has none: the user's own AI reads
    /// the transcript through MCP. Whatever it returns goes under "## Summary" in the note.
    public typealias Summarizer = @Sendable (Transcript) async -> String?

    public nonisolated let spool: Spool
    private var settings: Settings
    private var engine: Engine?
    private var engineLoad: Task<Engine, Error>?
    private var currentID: String?
    /// Seconds to keep of the conversation being transcribed, when "delete the last N minutes" cut it meanwhile.
    private var cuts: [String: Double] = [:]
    private var queue: [String] = []
    private var running = false
    /// Keep the models between drains (see `keepEngineLoaded`).
    private var keepsEngine = false
    /// Load the models for the CPU alone (see `useCPUOnly`).
    private var cpuOnly = false
    private var state = State()
    private let onState: @Sendable (State) -> Void
    private var summarizer: Summarizer?
    /// Tests only: stands in for the models.
    private var transcriber: (@Sendable (URL, Date) async throws -> Transcript)?
    func useTranscriber(_ t: @escaping @Sendable (URL, Date) async throws -> Transcript) { transcriber = t }
    public static let maxAttempts = 3

    public init(spool: Spool, settings: Settings, summarizer: Summarizer? = nil, onState: @escaping @Sendable (State) -> Void = { _ in }) {
        self.spool = spool
        self.settings = settings
        self.summarizer = summarizer
        self.onState = onState
        NoteWriter.tightenPermissions(settings.conversationsURL)  // notes written before they were private
    }

    public func update(settings new: Settings) {
        if new.model != settings.model {
            engine = nil
            engineLoad = nil
        }
        settings = new
    }

    /// Loads the engine now (so the first conversation doesn't wait for it).
    public func warmUp() async throws {
        _ = try await ensureEngine()
    }

    /// Keeps the models loaded when the queue runs dry, until `unload()`. The iPhone hands over one recording at a time
    /// (so it can stop between them when the app leaves the screen), and would otherwise reload the models for each one
    /// of a backlog. The Mac never sets it.
    public func keepEngineLoaded(_ keep: Bool) { keepsEngine = keep }

    /// The CPU alone from the next load on: an iPhone app in the background (iOS 27 refuses it the Neural Engine
    /// without the Background Inference entitlement). Slower, but a note gets written. The engine loaded now goes
    /// (a note being written keeps its own and finishes). The Mac never sets it.
    public func useCPUOnly(_ on: Bool) {
        guard on != cpuOnly else { return }
        cpuOnly = on
        unload()
    }

    /// Frees the models (the queue is empty, or always-on was turned off); the next conversation loads them again.
    /// A note being written keeps its own reference and finishes.
    public func unload() {
        engine = nil
        engineLoad = nil
    }

    /// Queues a conversation in the spool. `speakers`: a speaker-count prior for it (the live pass saw 3 people,
    /// say), stored with the entry before anything else so it survives a crash. An entry that already has one
    /// (`sona file --speakers`) keeps it.
    public func enqueue(_ id: String, speakers: SpeakerHint? = nil) {
        remember(speakers, for: id)
        guard !queue.contains(id) else { return }
        queue.append(id)
        if !running {
            running = true  // set now, not when the task starts, so only one drain ever runs
            Task { await drain() }
        }
        publish()
    }

    /// Stores a speaker-count hint with a conversation without queueing it (quitting: it's transcribed next launch).
    public func remember(_ speakers: SpeakerHint?, for id: String) {
        guard let speakers, !speakers.isEmpty, var entry = spool.load(id), entry.speakers == nil else { return }
        entry.speakers = speakers
        spool.save(entry, durable: true)
        Log.note("conversation \(Log.ref(entry.startedAt)): live pass heard \(speakers) speaker(s), passed on as a hint")
    }

    /// Everything left in the spool from before (a crash, a quit mid-conversation, a failure).
    /// `onlyClosed`: skip conversations still being recorded (for retries while the app runs). The one the
    /// Listener is recording into right now (`spool.openID`) is always skipped.
    @discardableResult
    public func recover(onlyClosed: Bool = false) -> Int {
        let recording = spool.openID
        let entries = spool.pending().filter { (!onlyClosed || $0.closed) && $0.id != recording }
        for entry in entries { enqueue(entry.id) }
        if !entries.isEmpty { Log.note("recovering \(entries.count) conversation(s) from the spool") }
        return entries.count
    }

    public func waitUntilIdle() async {
        while running || !queue.isEmpty { try? await Task.sleep(nanoseconds: 100_000_000) }
    }

    public var current: State { state }

    /// Notes written by this processor, in order (for the CLI).
    public private(set) var written: [URL] = []

    /// A clean quit mid-transcription isn't the conversation's fault: don't count it as a failed attempt.
    public func quitting() {
        guard let id = currentID, var entry = spool.load(id), entry.attempts > 0 else { return }
        entry.attempts -= 1
        spool.save(entry)
    }

    /// "Delete the last N minutes": nothing heard from `cut` on may become (or stay in) a note. Conversations in
    /// the spool (and in Spool/failed) lose their audio from `cut` on, or go if they started after it; the one
    /// being transcribed right now loses those words when they come back (its file is replaced, never cut under
    /// the reader); notes already written are cut or deleted (`NoteStore.forget`). The conversation still being
    /// recorded is the Listener's (`Listener.forget`). Runs between the steps of a note being written, never
    /// during one.
    public func forget(from cut: Date) -> NoteStore.Forgotten {
        let recording = spool.openID
        for entry in spool.pending() where entry.id != recording {
            if forget(entry, in: spool, from: cut, beingRead: entry.id == currentID) { queue.removeAll { $0 == entry.id } }
        }
        let failed = Spool(dir: spool.failedDir(), create: false)
        for entry in failed.pending(readOnly: true) { forget(entry, in: failed, from: cut, beingRead: false) }
        publish()
        return NoteStore(root: settings.conversationsURL).forget(from: cut)
    }

    /// One conversation's audio from `cut` on goes; all of it if it started after (or can't be cut). True if
    /// it's gone.
    @discardableResult
    private func forget(_ entry: SpoolEntry, in spool: Spool, from cut: Date, beingRead: Bool) -> Bool {
        var entry = entry
        let keep = cut.timeIntervalSince(entry.startedAt)
        let wav = spool.wav(entry.id)
        guard keep < WavFile.duration(of: wav) else { return false }  // all of it from before
        if beingRead { cuts[entry.id] = min(cuts[entry.id] ?? keep, keep) }
        var cutDone = false
        if keep > 0 {
            do {
                if beingRead { try WavFile.cut(wav, to: keep) } else { try WavFile.repair(wav, truncatingTo: keep) }
                cutDone = true
            } catch {
                Log.note("conversation \(Log.ref(entry.startedAt)) couldn't be cut: \(Log.describe(error))")
            }
        }
        // The Mac's audio from the cut on goes too: all of it if it started after.
        let mac = spool.macWav(entry.id)
        if let offset = entry.mac?.offset, FileManager.default.fileExists(atPath: mac.path) {
            let macKeep = keep - offset
            do {
                guard cutDone, macKeep > 0 else { throw CocoaError(.fileWriteUnknown) }
                if beingRead { try WavFile.cut(mac, to: macKeep) } else { try WavFile.repair(mac, truncatingTo: macKeep) }
            } catch {
                try? FileManager.default.removeItem(at: mac)
            }
        }
        guard cutDone else {
            spool.remove(entry.id)
            Log.note("conversation \(Log.ref(entry.startedAt)) deleted before it became a note")
            return true
        }
        entry.closed = true
        entry.speechEnd = keep
        entry.speechSeconds = min(entry.speechSeconds, keep)
        spool.save(entry, durable: true)
        Log.note("conversation \(Log.ref(entry.startedAt)) cut to \(fmt(keep, 1)) s before it became a note")
        return false
    }

    private func drain() async {
        running = true
        state.busy = true
        publish()
        while !queue.isEmpty {
            let id = queue.removeFirst()
            currentID = id
            let ok = await processOne(id)
            currentID = nil
            if !ok, case .some = state.lastError, !Models.isReady(model: settings.model) {
                // No models: stop and keep everything in the spool until they're downloaded.
                queue.removeAll()
                break
            }
        }
        running = false
        state.busy = false
        state.failed = spool.failedCount()
        // Nothing left to write: let the models go (their buffers with them). The next conversation loads them
        // again (0.2-0.7 s). Unless the host asked to keep them (`keepEngineLoaded`) and lets them go itself.
        if !keepsEngine { unload() }
        publish()
    }

    /// One shared load, however many callers ask at once.
    private func ensureEngine() async throws -> Engine {
        if let engine, engine.model == settings.model, engine.cpuOnly == cpuOnly { return engine }
        if let engineLoad { return try await engineLoad.value }
        let model = settings.model, cpuOnly = cpuOnly
        let load = Task { try await Engine.load(model: model, cpuOnly: cpuOnly) }
        engineLoad = load
        do {
            let loaded = try await load.value
            engine = loaded
            engineLoad = nil
            return loaded
        } catch {
            engineLoad = nil
            throw error
        }
    }

    private func processOne(_ id: String) async -> Bool {
        defer { cuts[id] = nil }
        // Still being recorded: it's enqueued again when the Listener closes it.
        guard id != spool.openID else { return true }
        guard var entry = spool.load(id) ?? spool.pending().first(where: { $0.id == id }) else { return true }
        let wav = spool.wav(id)
        let wasOpen = !entry.closed
        // Always fix the WAV header from the file's length: a closed entry's can still say 0 bytes when
        // finishing it failed (a full disk, say). Closed: cut at the end it was closed at. Left open by a
        // crash or a kill: keep all of it (the last checkpoint can be a few seconds behind the last words,
        // and trailing quiet costs nothing).
        try? WavFile.repair(wav, truncatingTo: entry.closed && entry.speechEnd > 0 ? entry.speechEnd : nil)
        if !entry.closed {
            entry.closed = true
            entry.speechEnd = WavFile.duration(of: wav)
            Log.note("conversation \(Log.ref(entry.startedAt)) recovered unfinished (spool \(id))")
        }
        // Blips are dropped, but never on a crash-recovered entry's checkpoint alone (it can lag the audio).
        let tooShort = wasOpen ? WavFile.duration(of: wav) < 1 : (entry.speechSeconds > 0 && entry.speechSeconds < 1.5)
        // Under half a second is never a recording, whatever made it (the model can't take it, so it would fail three
        // times and sit in Spool/failed); the stricter blip rule is only for what the always-on mic heard.
        if WavFile.duration(of: wav) < 0.5 || (entry.source == nil && tooShort) {
            Log.note("conversation \(Log.ref(entry.startedAt)) dropped: too little audio")
            spool.remove(id)
            return true
        }
        // Started maxAttempts times and never came back (the app was killed or crashed mid-transcription: a thrown
        // error would have reached the catch below). Stop retrying it, keep its audio, and let the newer ones through.
        // Before the models load, so a recording going straight to Spool/failed costs nothing.
        if entry.attempts >= Self.maxAttempts {
            spool.fail(id)
            state.lastError = "A recording kept stopping Sona while it was transcribed. Its audio is kept."
            Log.note("moved \(id) to Spool/failed: \(entry.attempts) attempts never finished (audio kept)")
            return false
        }

        do {
            let engine = transcriber == nil ? try await ensureEngine() : nil
            // "Delete the last N minutes" can land at any await from here on (`forget`): its files are cut already.
            if let keep = cuts[id] {
                guard keep > 0 else { return true }
                entry.speechEnd = min(entry.speechEnd, keep)
            }
            entry.attempts += 1
            spool.save(entry)
            let t0 = Date()
            var transcript: Transcript
            if let engine {
                transcript = try await engine.process(wav: wav, startedAt: entry.startedAt, speakers: entry.speakers)
            } else {
                transcript = try await transcriber!(wav, entry.startedAt)
            }
            if let merged = try await addMac(entry, to: transcript, engine: engine) { transcript = merged }
            if let keep = cuts[id] { transcript = transcript.cut(at: keep) }
            // No words: on the Mac's always-on mic that's noise, dropped. A recording someone made on purpose (the iPhone,
            // the watch) is kept, as a note that says no speech was transcribed, with its audio: whispered, muffled or in
            // another language, it's still theirs, and the watch has already deleted its copy.
            guard !transcript.words.isEmpty || NoteSource.isDeliberate(entry.source) else {
                Log.note("conversation \(Log.ref(entry.startedAt)) had no words, dropped")
                spool.remove(id)
                return true
            }
            var summary = await summarizer?(transcript)
            if let keep = cuts[id] {
                // Only what was said before, and no summary (it may tell of the rest).
                transcript = transcript.cut(at: keep)
                entry.speechEnd = min(entry.speechEnd, max(keep, 0))
                summary = nil
                if transcript.words.isEmpty {
                    spool.remove(id)
                    return true
                }
            }
            let media = Playback.mediaReason(fraction: entry.playback)
            // The note's name is saved with the entry before anything is written to it, so a retry after a
            // crash before `spool.remove` overwrites that note instead of writing "... 2".
            let conversations = settings.conversationsURL
            // Relative to Conversations (an older absolute path keeps its last two parts: day/name).
            let reuse = entry.note.map { saved -> URL in
                let parts = saved.split(separator: "/").suffix(2).joined(separator: "/")
                return conversations.appendingPathComponent(parts)
            }
            let note = try NoteWriter.write(
                transcript, to: conversations, source: entry.source, summary: summary, media: media,
                words: WordFixer(settings.words), reuse: reuse
            ) { reserved in
                entry.note = reserved.deletingLastPathComponent().lastPathComponent + "/" + reserved.lastPathComponent
                // If the reservation can't be saved, don't write: a retry would make a second note.
                guard spool.save(entry, durable: true) else {
                    throw CocoaError(.fileWriteUnknown, userInfo: [NSLocalizedDescriptionKey: "couldn't save the spool entry"])
                }
            }
            if settings.keepAudio {
                // The kept audio is part of the note: if it can't be moved beside it, the spool keeps it (never deleted
                // below) and this try fails. The note's .json goes, so the note isn't whole and never syncs without its
                // audio; the retry writes the same note again (its name is reserved in the entry).
                let fm = FileManager.default
                func keep(_ from: URL, as ext: String) throws {
                    guard fm.fileExists(atPath: from.path) else { return }  // cut away by "delete the last N minutes"
                    let to = note.deletingPathExtension().appendingPathExtension(ext)
                    try? fm.removeItem(at: to)  // a retry's
                    do {
                        try fm.moveItem(at: from, to: to)
                    } catch {
                        guard fm.fileExists(atPath: from.path) else { return }
                        try? fm.removeItem(at: note.deletingPathExtension().appendingPathExtension("json"))
                        throw error
                    }
                    chmod(to.path, 0o600)
                }
                try keep(wav, as: "wav")
                do {
                    try keep(spool.macWav(id), as: "mac.wav")
                } catch {
                    // The room's audio goes back too, so the retry has all it had (a spool entry without its WAV
                    // would be dropped as too short).
                    let kept = note.deletingPathExtension().appendingPathExtension("wav")
                    if !fm.fileExists(atPath: wav.path) { try? fm.moveItem(at: kept, to: wav) }
                    throw error
                }
            } else {
                // The spool's audio is about to go and no copy is kept: the note's words must be on disk first, or a
                // power cut now could lose both. If they can't be flushed, the recording stays for the retry.
                try Self.syncToDisk([note, note.deletingPathExtension().appendingPathExtension("json")])
            }
            spool.remove(id)
            let took = Date().timeIntervalSince(t0)
            Log.note(
                "note written: \(Log.ref(entry.startedAt)) (\(fmt(transcript.duration, 1)) s audio in \(fmt(took)) s, "
                    + "\(fmt(transcript.duration / max(took, 0.001), 1))x real time, \(transcript.speakers.count) speakers"
                    + "\(entry.speakers.map { " (hint \($0))" } ?? "")\(media == nil ? "" : ", likely media"))")
            state.lastNote = note
            state.lastError = nil
            written.append(note)
            return true
        } catch {
            Log.note("couldn't process conversation \(Log.ref(entry.startedAt)) (spool \(id), attempt \(entry.attempts)): \(Log.describe(error))")
            state.lastError = Log.describe(error)  // shown in the menu: never a note path (it holds the title)
            if entry.attempts >= Self.maxAttempts {
                spool.fail(id)
                Log.note("moved \(id) to Spool/failed after \(entry.attempts) attempts (audio kept)")
            }
            return false
        }
    }

    /// Flushes each file to disk, then their folder, so the renames that put them there stick too. F_FULLFSYNC, like the
    /// spool's checkpoints: on macOS plain fsync can leave them in the drive's own cache, which a power cut loses. Plain
    /// fsync where a disk doesn't take F_FULLFSYNC (some network and external ones). Throws if a file can't be opened or
    /// flushed.
    static func syncToDisk(_ files: [URL]) throws {
        for file in files {
            let handle = try FileHandle(forWritingTo: file)
            defer { try? handle.close() }
            if fcntl(handle.fileDescriptor, F_FULLFSYNC) != 0 { try handle.synchronize() }
        }
        guard let dir = files.first?.deletingLastPathComponent() else { return }
        let fd = Darwin.open(dir.path, O_RDONLY)
        if fd >= 0 {
            if fcntl(fd, F_FULLFSYNC) != 0 { _ = Darwin.fsync(fd) }
            _ = Darwin.close(fd)
        }
    }

    private func publish() {
        state.pending = queue.count + (running ? 1 : 0)
        onState(state)
    }

    /// The conversation's Mac track, if it has one worth transcribing: transcribed on its own with the same models
    /// (no speaker hint: the live count is the room's), then merged with the mic's (`MacTrackMerge`).
    private func addMac(_ entry: SpoolEntry, to mic: Transcript, engine: Engine?) async throws -> Transcript? {
        let wav = spool.macWav(entry.id)
        guard let offset = entry.mac?.offset, FileManager.default.fileExists(atPath: wav.path) else { return nil }
        try? WavFile.repair(wav, truncatingTo: entry.closed && entry.speechEnd > offset ? entry.speechEnd - offset : nil)
        guard WavFile.duration(of: wav) >= 0.5 else { return nil }
        let start = entry.startedAt.addingTimeInterval(offset)
        let mac: Transcript
        if let engine {
            mac = try await engine.process(wav: wav, startedAt: start)
        } else {
            mac = try await transcriber!(wav, start)
        }
        let merged = MacTrackMerge.combine(
            mic: mic, mac: mac, offset: offset, micCurve: MacTrackMerge.curve(of: spool.wav(entry.id)),
            macCurve: MacTrackMerge.curve(of: wav))
        Log.note(
            "conversation \(Log.ref(entry.startedAt)): \(merged.macWords) word(s) of this Mac's audio, \(merged.echoes) mic word(s) "
                + "flagged as its echo (\(fmt(merged.gateSeconds, 1)) s matched by loudness)")
        return merged.transcript
    }
}
