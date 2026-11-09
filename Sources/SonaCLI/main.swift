import AppKit  // NSRunningApplication only
import FluidAudio
import Foundation
import NotesKit
import SonaEngine

let usage = """
    sona: fully local always-on notetaker (Parakeet + offline diarization on the Neural Engine)

    USAGE
      sona file <audio> [options]       Transcribe + diarize one audio file into a note (same pipeline as the app)
      sona simulate <audio> [options]   Feed a file through the always-on listener (VAD + quiet split) at full speed
      sona process-spool                Turn anything left in the spool (after a crash) into notes
      sona import-phone [--from PATH]   Copy the iPhone app's notes (from iCloud Drive) into the notes folder
      sona models [--model v2|v3]       Download the models (one time, then fully offline)
      sona mcp                          Run the MCP server on stdio (same as sona-mcp)
      sona status                       Settings, models, spool and app state

    OPTIONS
      --model v2|v3            Parakeet TDT 0.6B v2 (English, default) or v3 (25 languages)
      --notes-dir <path>       Notes folder for this run (default: from settings, ~/Sona)
      --keep-audio             Keep the audio (.wav) next to the note
      --speakers <n|min-max>   How many people spoke, if you know (file only): 3, 2-4, 2- or -4.
                               A prior for the diarizer: it only changes a count outside the range

    IMPORT-PHONE ONLY
      --from <path>            One folder of the iPhone's notes (default: "iCloud Drive/Sona/Conversations" and the
                               app's own iCloud folder, whichever exist; in a test home, $SONA_HOME/PhoneInbox).
                               No note is ever deleted; a note already copied isn't copied again

    SIMULATE ONLY
      --quiet-seconds <n>      Quiet that ends a conversation (default: the quiet minutes setting)
      --crash-after <seconds>  SIGKILL itself after feeding this much audio (tests crash recovery)
      --split-seconds <n>      Split a long conversation at a pause past this length (default 3600; tests)

    Support folder: ~/Library/Application Support/Sona (or $SONA_HOME)
    """

struct Options {
    var command = ""
    var input: String?
    var model: String?
    var notesDir: String?
    var keepAudio = false
    var quietSeconds: Double?
    var crashAfter: Double?
    var splitSeconds: Double?
    var speakers: SpeakerHint?
    var from: String?

    static func parse(_ args: [String]) throws -> Options {
        var o = Options()
        var it = args.makeIterator()
        guard let command = it.next() else { throw Failure("missing command") }
        o.command = command
        func value(_ flag: String) throws -> String {
            guard let v = it.next() else { throw Failure("\(flag) needs a value") }
            return v
        }
        func number(_ flag: String) throws -> Double {
            let raw = try value(flag)
            guard let d = Double(raw), d > 0 else { throw Failure("\(flag) needs a positive number, got \(raw)") }
            return d
        }
        while let arg = it.next() {
            switch arg {
            case "--model":
                o.model = try value(arg)
                guard ["v2", "v3"].contains(o.model!) else { throw Failure("--model must be v2 or v3") }
            case "--notes-dir": o.notesDir = try value(arg)
            case "--from": o.from = try value(arg)
            case "--keep-audio": o.keepAudio = true
            case "--quiet-seconds": o.quietSeconds = try number(arg)
            case "--crash-after": o.crashAfter = try number(arg)
            case "--split-seconds": o.splitSeconds = try number(arg)
            case "--speakers":
                let raw = try value(arg)
                guard let hint = SpeakerHint(parsing: raw) else {
                    throw Failure("--speakers needs a count (3) or a range (2-4, 2-, -4), got \(raw)")
                }
                o.speakers = hint
            case "-h", "--help": o.command = "help"
            default:
                if arg.hasPrefix("-") || o.input != nil { throw Failure("unknown argument \(arg)") }
                o.input = arg
            }
        }
        return o
    }

    func settings() -> Settings {
        var s = Settings.load()
        if let model { s.model = model }
        if let notesDir { s.notesFolder = (notesDir as NSString).expandingTildeInPath }
        if keepAudio { s.keepAudio = true }
        return s
    }
}

struct Failure: Error, CustomStringConvertible {
    let description: String
    init(_ d: String) { description = d }
}

func say(_ s: String) { FileHandle.standardError.write(Data((s + "\n").utf8)) }
func fmt(_ x: Double, _ d: Int = 2) -> String { String(format: "%.\(d)f", x) }

let options: Options
do {
    options = try Options.parse(Array(CommandLine.arguments.dropFirst()))
} catch {
    say("error: \(error)\n")
    print(usage)
    exit(2)
}

if options.speakers != nil, options.command != "file" {
    say("error: --speakers only works with `sona file`\n")
    exit(2)
}
if options.from != nil, options.command != "import-phone" {
    say("error: --from only works with `sona import-phone`\n")
    exit(2)
}
if options.command != "mcp" { Log.echoToStderr = true }
Models.goOffline()  // `sona models` turns it off only while downloading

do {
    switch options.command {
    case "file": try await runFile(options)
    case "simulate": try await runSimulate(options)
    case "process-spool": try await runProcessSpool(options)
    case "import-phone": try runImportPhone(options)
    case "models": try await runModels(options)
    // Same switch as sona-mcp: no settings file, or one that can't be read, is AI access off.
    case "mcp": MCPServer(store: NoteStore(settings: options.settings()), enabled: { Settings.aiAccessAllowed }).run()
    case "status": runStatus(options)
    case "help", "-h", "--help": print(usage)
    default:
        say("error: unknown command \(options.command)\n")
        print(usage)
        exit(2)
    }
} catch {
    say("error: \(error)")
    exit(1)
}

func requireModels(_ settings: Settings) throws {
    guard Models.isReady(model: settings.model) else {
        throw Failure("models for \(settings.model) aren't downloaded. Run `sona models --model \(settings.model)` first.")
    }
}

/// The app's spool is the app's: don't process it under a running app. Without the lock (its file can't be opened),
/// only the running apps can tell.
func requireAppNotRunning() throws -> AppLock {
    let running = Failure(
        "the Sona app is running and owns the spool. Quit it first, or set SONA_HOME to a test folder.")
    guard let lock = AppLock.acquire() else { throw running }
    if !lock.isHeld, !NSRunningApplication.runningApplications(withBundleIdentifier: "com.dinilb.sona").isEmpty { throw running }
    return lock
}

func runFile(_ options: Options) async throws {
    guard let input = options.input else { throw Failure("sona file needs an audio path") }
    let url = URL(fileURLWithPath: (input as NSString).expandingTildeInPath)
    guard FileManager.default.fileExists(atPath: url.path) else { throw Failure("no such file: \(url.path)") }
    let settings = options.settings()
    try requireModels(settings)

    // Same path as a live conversation: a WAV in a spool, then the processor. Its own spool, so it
    // never touches the app's.
    let spool = Spool(dir: FileManager.default.temporaryDirectory.appendingPathComponent("sona-file-\(getpid())"))
    defer { try? FileManager.default.removeItem(at: spool.dir) }

    let t0 = Date()
    var entry = SpoolEntry(
        id: Spool.newID(for: Date()), startedAt: Date(), source: url.lastPathComponent, speakers: options.speakers)
    let wav = try WavFile(creating: spool.wav(entry.id))
    let reader = try AudioFileReader(url: url)
    while let chunk = try reader.next() { try wav.append(chunk) }
    let audioSeconds = Double(wav.samples) / 16_000
    try wav.finish()
    entry.speechEnd = audioSeconds
    entry.speechSeconds = audioSeconds
    entry.closed = true
    spool.save(entry)
    let decodeSeconds = Date().timeIntervalSince(t0)

    let processor = Processor(spool: spool, settings: settings)
    let t1 = Date()
    try await processor.warmUp()
    let loadSeconds = Date().timeIntervalSince(t1)
    let t2 = Date()
    await processor.enqueue(entry.id)
    await processor.waitUntilIdle()
    let processSeconds = Date().timeIntervalSince(t2)

    guard let note = await processor.written.first else {
        throw Failure((await processor.current.lastError) ?? "no note written (no words transcribed?)")
    }
    let json = note.deletingPathExtension().appendingPathExtension("json")
    if let data = try? Data(contentsOf: json), let side = try? JSONDecoder().decode(NoteWriter.Sidecar.self, from: data) {
        say(
            "audio \(fmt(audioSeconds, 1)) s · decode \(fmt(decodeSeconds)) s · model load \(fmt(loadSeconds)) s · "
                + "ASR \(fmt(side.timing.asrSeconds)) s · diarization \(fmt(side.timing.diarizationSeconds)) s · "
                + "process total \(fmt(processSeconds)) s · \(fmt(audioSeconds / processSeconds, 1))x real time")
        say(
            "speakers: \(side.speakers.joined(separator: ", "))"
                + (options.speakers.map { " (hint: \($0))" } ?? ""))
    }
    print(note.path)
}

func runSimulate(_ options: Options) async throws {
    guard let input = options.input else { throw Failure("sona simulate needs an audio path") }
    let url = URL(fileURLWithPath: (input as NSString).expandingTildeInPath)
    let settings = options.settings()
    try requireModels(settings)
    let lock = try requireAppNotRunning()
    defer { withExtendedLifetime(lock) {} }

    let quiet = options.quietSeconds ?? settings.quietMinutes * 60
    let reader = try AudioFileReader(url: url, chunkSeconds: 10)
    say("simulating \(fmt(reader.duration, 1)) s of audio through the listener, quiet split \(fmt(quiet, 1)) s")

    let spool = Spool()
    let processor = Processor(spool: spool, settings: settings)
    try await processor.warmUp()
    let vad = try await Models.loadVAD(threshold: 0.6)
    var config = Listener.Config(quietSeconds: quiet)
    if let split = options.splitSeconds {
        config.splitAfterSeconds = split
        config.maxSeconds = split * 1.25
    }
    let listener = await Listener(vad: vad, spool: spool, config: config)
    let base = Date()
    let frame = 1_600  // 100 ms, like the mic
    var fed = 0
    listener.onEvent = { event in
        let at = fmt(Double(fed) / 16_000, 1)
        switch event {
        case .opened(let d): say("  [\(at)s] conversation opened (starts \(NoteWriter.timeString(d, "HH:mm:ss")))")
        case .closed(let e):
            say("  [\(at)s] conversation closed: \(fmt(e.speechEnd, 1)) s audio, \(fmt(e.speechSeconds, 1)) s speech -> processing")
            Task { await processor.enqueue(e.id) }
        case .discarded: say("  [\(at)s] conversation dropped (too little speech)")
        case .speech: break
        }
    }
    let t0 = Date()
    while let samples = try reader.next() {
        var i = 0
        while i < samples.count {
            let end = min(i + frame, samples.count)
            try await listener.feed(Array(samples[i..<end]), at: base.addingTimeInterval(Double(fed) / 16_000))
            fed += end - i
            i = end
            if let crash = options.crashAfter, Double(fed) / 16_000 >= crash {
                say("  [\(fmt(crash, 1))s] --crash-after: SIGKILL now, mid-conversation")
                kill(getpid(), SIGKILL)
            }
        }
    }
    // The file ended: let the quiet run out like the room going silent.
    let tail = [Float](repeating: 0, count: Int((quiet + 1) * 16_000))
    var t = 0
    while t < tail.count, listener.conversationStartedAt != nil {
        let end = min(t + frame, tail.count)
        try await listener.feed(Array(tail[t..<end]), at: base.addingTimeInterval(Double(fed + t) / 16_000))
        t = end
    }
    try listener.close(reason: "end of file")
    let feedSeconds = Date().timeIntervalSince(t0)
    try? await Task.sleep(nanoseconds: 200_000_000)
    await processor.waitUntilIdle()
    say("fed in \(fmt(feedSeconds)) s, all done in \(fmt(Date().timeIntervalSince(t0))) s")
    for note in await processor.written { print(note.path) }
}

func runProcessSpool(_ options: Options) async throws {
    let settings = options.settings()
    try requireModels(settings)
    let lock = try requireAppNotRunning()
    defer { withExtendedLifetime(lock) {} }
    let processor = Processor(spool: Spool(), settings: settings)
    let n = await processor.recover()
    say("\(n) conversation(s) in the spool")
    await processor.waitUntilIdle()
    for note in await processor.written { print(note.path) }
    if let error = await processor.current.lastError { throw Failure(error) }
}

/// Copies the iPhone's notes into the notes folder, once: the same as the app does every minute, and safe beside
/// it (one import at a time). It only reads the iPhone's folders, and never deletes a note there or here (only its own
/// temp copies a killed import left behind).
func runImportPhone(_ options: Options) throws {
    // Settings that can't be read give the default notes folder, which may not be the user's: the iPhone's notes
    // (ones deleted from the user's folder too) would be copied into it.
    if options.notesDir == nil, Settings.loadChecked().unreadable {
        throw Failure("settings.json can't be read, so the notes folder isn't known. Fix it, or name the folder with --notes-dir.")
    }
    let settings = options.settings()
    let wanted = options.from.map { [URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath, isDirectory: true)] }
        ?? PhoneImport.defaultSources
    let folders = wanted.filter { FileManager.default.fileExists(atPath: $0.path) }
    guard !folders.isEmpty else {
        throw Failure(
            options.from != nil
                ? "no such folder: \(wanted[0].path)"
                : "no iPhone notes folder on this Mac. Looked in: \(wanted.map(\.path).joined(separator: ", "))")
    }
    for folder in folders { say("from \(folder.path)") }
    say("into \(settings.conversationsURL.path)")
    let summary = PhoneImport.run(from: folders, to: settings.conversationsURL, statePath: PhoneImport.defaultStatePath)
    if summary.busy { throw Failure("another import is running (the app does one every minute). Try again in a moment.") }
    print("imported \(summary.imported), updated \(summary.updated), unchanged \(summary.unchanged), skipped \(summary.skipped)")
    if summary.waiting > 0 { say("\(summary.waiting) not all there yet (still coming from iCloud): run it again in a minute") }
    if summary.kept > 0 { say("\(summary.kept) changed on the iPhone but were edited or deleted here, so this Mac's copy stays") }
}

func runModels(_ options: Options) async throws {
    let settings = options.settings()
    if Models.isReady(model: settings.model) {
        say("\(Models.displayName(settings.model)) is already downloaded in \(Paths.models.path)")
        return
    }
    say(
        "downloading \(Models.displayName(settings.model)), the speaker model and the voice detector "
            + "(about \(Models.downloadMB(model: settings.model)) MB, one time)")
    let last = Locked(-1)
    try await Models.prepare(model: settings.model) { fraction, phase in
        let pct = Int(fraction * 100)
        if last.swap(pct) != pct { say("  \(pct)% \(phase)") }
    }
    say("done: \(Paths.models.path)")
}

func runStatus(_ options: Options) {
    let s = options.settings()
    print("support folder: \(Paths.support.path)")
    print("notes folder:   \(s.notesURL.path)")
    print("model:          \(Models.displayName(s.model)) (\(Models.isReady(model: s.model) ? "downloaded" : "NOT downloaded"))")
    print("always-on:      \(s.alwaysOn ? "on" : "off (dictation only)")")
    print("AI access:      \(s.mcp ? "on" : "off")")
    print("quiet minutes:  \(s.quietMinutes)")
    print("keep audio:     \(s.keepAudio)")
    // Only looks: the app may be recording into this spool right now.
    let spool = Spool(create: false)
    print("spool:          \(spool.pending(readOnly: true).count) waiting, \(spool.failedCount()) failed")
    if let st = AppStatus.read() {
        print("app:            running (pid \(st.pid)), \(st.state)\(st.detail.map { ": \($0)" } ?? "")")
    } else {
        print("app:            not running")
    }
    print("conversations:  \(NoteStore(settings: s).conversations().count)")
}

// @unchecked: `value` is only touched under `lock`.
final class Locked<T>: @unchecked Sendable {
    private var value: T
    private let lock = NSLock()
    init(_ v: T) { value = v }
    func swap(_ v: T) -> T {
        lock.lock()
        defer { lock.unlock() }
        let old = value
        value = v
        return old
    }
}
