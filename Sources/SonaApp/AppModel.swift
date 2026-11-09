import AVFoundation
import AppKit
import LiveCore
import NotesKit
import SonaEngine

/// What the window shows.
enum SidebarItem: Hashable {
    case now
    case dictations
    case settings
    case about
    /// A day's conversations, `2026-10-29`.
    case day(String)
    case conversation(String)

    /// The sidebar row that shows as selected: a conversation's is its day.
    var row: SidebarItem {
        if case .conversation(let id) = self { return .day(String(id.prefix(10))) }
        return self
    }
}

/// Test runs (`LIVE_FILE` plays a file instead of the mic, `LIVE_SNAPSHOT` saves the window as a PNG and quits):
/// no focus stealing, no menu bar icon, no fn takeover, no launch agent, and only with `SONA_HOME` set.
enum TestRun {
    static let file = env("LIVE_FILE")
    /// Played as this Mac's audio (instead of a Core Audio tap) beside `LIVE_FILE`, from the same moment.
    static let fileMac = env("LIVE_FILE_MAC")
    static let snapshot = env("LIVE_SNAPSHOT")
    /// `LIVE_DICTATE=1.0-4.2,8.0-11.5`: the dictation key held over those seconds of the test file (see TestDictation).
    static let dictate = env("LIVE_DICTATE").map(TestDictation.parse)
    static var isOn: Bool { file != nil || snapshot != nil }
    /// The host time both test files count as starting from (set the first time either opens).
    static let clockStart = hostNow() + 0.5

    private static func env(_ name: String) -> String? {
        ProcessInfo.processInfo.environment[name].flatMap { $0.isEmpty ? nil : $0 }
    }
}

/// Everything the app does, on the main thread: settings and pause, the one mic (through `MicDriver`), the live
/// session (Now, dictation, `now.json`), the always-on recorder, and the status the MCP server reads.
@MainActor
@Observable
final class AppModel {
    enum LiveState: Equatable {
        case loading(Double, String)
        case ready
        case failed(String)
    }

    private(set) var settings: Settings { didSet { writeStatus() } }
    var selection: SidebarItem? = .now
    /// The window is open: Now's level dot and lag are only kept up to date then.
    var windowOpen = false { didSet { runMeter() } }
    /// Some of the window can be seen (open, not minimised or covered): only then does Now get new lines.
    @ObservationIgnored var windowVisible = false { didSet { if windowVisible, !oldValue { showLinesNow() } } }

    private(set) var live = LiveState.loading(0, "Loading the speech model...") { didSet { writeStatus() } }
    /// Now's copy of `currentLines`, for the window: at most 4 times a second, and only while it can be seen.
    private(set) var lines: [LiveLine] = []
    private(set) var speakersActive = false
    private(set) var lagMs: Double?
    private(set) var level: Float = -90
    /// Words in the last 2 s.
    private(set) var hearing = false { didSet { if hearing != oldValue { writeStatus() } } }
    private(set) var mic = MicHealth.State.off {
        didSet {
            writeStatus()
            // `LIVE_DICTATE`: the test file is playing, so its clock has started.
            if mic == .running, let holds = TestRun.dictate, testDictation == nil { testDictation = TestDictation(holds, dictation: dictation) }
        }
    }
    private(set) var micAllowed = TestRun.file != nil
    private(set) var micDenied = false { didSet { writeStatus() } }
    /// Always-on recording is set up (the Listener is taking audio).
    private(set) var recording = false
    /// The notes models' download, or why it failed; nil once they're there.
    private(set) var notesSetup: String? { didSet { writeStatus() } }
    private(set) var notesFailed = false
    private(set) var conversationStartedAt: Date? { didSet { writeStatus() } }
    private(set) var processing = Processor.State() { didSet { writeStatus() } }
    /// Hearing this Mac's audio: off (nothing playing, or the switch off), on, or a problem to show in Settings.
    private(set) var macAudio = MacAudioDriver.State.off
    /// What turning Open at login on or off said, if anything.
    private(set) var loginMessage: String?
    /// The live set's load (and first download) has been started: by the first-run screen, or once listening.
    private(set) var liveStarted = false
    let dictation = Dictation()
    let library = Library()

    /// Listening has begun (the first-run screen is done): the mic, dictation and recording only exist after.
    @ObservationIgnored private var begun = false
    /// The first run just ended, where the Accessibility step was offered: don't ask again at once.
    @ObservationIgnored private var skipAccessibilityPrompt = false
    /// The words list, ready to apply.
    @ObservationIgnored private var fixer = WordFixer.none
    /// The transcript's lines before the words list (to redo only the lines that changed).
    @ObservationIgnored private var rawLines: [LiveLine] = []
    /// The latest lines, words list applied: what Copy and now.json use, and Now gets (`lines`).
    @ObservationIgnored private var currentLines: [LiveLine] = []
    @ObservationIgnored private var linesChanged = false
    @ObservationIgnored private var linesShownAt = 0.0
    @ObservationIgnored private var linesPending: DispatchWorkItem?
    /// When words were last heard (`hearing` goes off 2 s after).
    @ObservationIgnored private var heardAt = 0.0
    /// Nil in the headless preview model, which never touches the mic (or this Mac's audio).
    @ObservationIgnored private var micDriver: MicDriver?
    @ObservationIgnored private var macDriver: MacAudioDriver?
    @ObservationIgnored private var engine: UnifiedEngine?
    /// The one engine, heard by the mic's session and the Mac's.
    @ObservationIgnored private var sharedEngine: SharedEngine?
    /// The Mac's audio as its own live session, while something plays: its own relay, voice gate and speakers.
    @ObservationIgnored private var macSession: LiveSession?
    @ObservationIgnored private var macRelay: RelaySource?
    @ObservationIgnored private var macSessionTask: Task<Void, Never>?
    @ObservationIgnored private var macTranscript = LiveTranscript()
    /// The Mac's speaker slots heard so far (one: "Mac audio"; more: numbered).
    @ObservationIgnored private var macSlots: Set<Int> = []
    /// Lines and words of the Mac's earlier sessions (it stopped playing, then played again), on the mic's clock.
    @ObservationIgnored private var pastMacLines: [LiveLine] = []
    @ObservationIgnored private var pastMacWords: [EchoFilter.Timed] = []
    /// Mic words that were the Mac's sound coming back through the speakers (absolute indices): never shown.
    @ObservationIgnored private var echoes: Set<Int> = []
    @ObservationIgnored private var asleep = false
    @ObservationIgnored private var diarizer: LiveDiarizer?
    @ObservationIgnored private var session: LiveSession?
    @ObservationIgnored private var relay: RelaySource?
    @ObservationIgnored private var sessionTask: Task<Void, Never>?
    /// The last speakers restart, so restarts run one after another.
    @ObservationIgnored private var restarting: Task<Void, Never>?
    @ObservationIgnored private var sessionFailures = 0
    @ObservationIgnored private var sessionStarted = Date.distantPast
    @ObservationIgnored private var transcript = LiveTranscript()
    @ObservationIgnored private var wallClock = WallClock()
    @ObservationIgnored private var speakerLog = SpeakerLog()
    /// When the speaker log started covering (a new session with speakers on).
    @ObservationIgnored private var speakerLogSince = Date.distantFuture
    @ObservationIgnored private var lag = LatencyStats(keepLast: 300)
    /// One spool and one processor for the app's life (made when always-on is first on), so two can never work
    /// the same conversation; the Listener (`recorder`) comes and goes with always-on.
    @ObservationIgnored private var notes: (spool: Spool, processor: Processor)?
    @ObservationIgnored private var recorder: Recorder?
    @ObservationIgnored private var liveTask: Task<Void, Never>?
    @ObservationIgnored private var recorderStarting = false
    @ObservationIgnored private var recorderStopping: Task<Void, Never>?
    @ObservationIgnored private var downloadingNotes = false
    @ObservationIgnored private var quitting = false
    /// Saving the speaker hint of the conversation closed by quitting.
    @ObservationIgnored private var lastHint: Task<Void, Never>?
    @ObservationIgnored private var lastRetry = Date()
    @ObservationIgnored private var lastLiveRetry = Date()
    /// The loop that copies the iPhone's notes in (`startPhoneImport`).
    @ObservationIgnored private var phoneImport: Task<Void, Never>?
    /// settings.json was there but couldn't be read, and no setting has been saved since: `settings` are defaults.
    @ObservationIgnored private var settingsUnreadable = false
    @ObservationIgnored private var heartbeat: Timer?
    @ObservationIgnored private var ticks = 0
    @ObservationIgnored private var meter: Timer?
    @ObservationIgnored private var hearingOff: DispatchWorkItem?
    @ObservationIgnored private var holding = false
    @ObservationIgnored private var lingerUntil = 0.0
    @ObservationIgnored private let feedQueue = DispatchQueue(label: "sona.feed", qos: .utility)
    @ObservationIgnored private var lastFeed: LiveFeed?
    @ObservationIgnored private var lastFeedBuild = 0.0
    @ObservationIgnored private var feedPending: DispatchWorkItem?
    @ObservationIgnored private var lastStatus: String?
    @ObservationIgnored private var lastStatusWrite = Date.distantPast
    @ObservationIgnored private var testDictation: TestDictation?

    init() {
        let loaded = Settings.loadChecked()
        settings = loaded.settings
        settingsUnreadable = loaded.unreadable
        if !FileManager.default.fileExists(atPath: Paths.settingsFile.path) { try? settings.save() }
        fixer = WordFixer(settings.words)
        // With a test file for the Mac's audio too, both start from one moment (read when the first opens). Test
        // dictations are timed from it as well.
        let start: (@Sendable () -> Double)? =
            TestRun.fileMac == nil && TestRun.dictate == nil ? nil : { @Sendable in TestRun.clockStart }
        micDriver = MicDriver(file: TestRun.file.map { URL(fileURLWithPath: $0) }, startHost: start, preferredUID: settings.micUID) {
            [weak self] state in MainActor.assumeIsolated { self?.mic = state }
        }
        // Test runs never tap this Mac: `LIVE_FILE_MAC` stands in for it, or there's none.
        macDriver = MacAudioDriver(file: TestRun.fileMac.map { URL(fileURLWithPath: $0) }) { [weak self] state in
            MainActor.assumeIsolated { self?.macAudioChanged(state) }
        }
    }

    /// The conversation a headless render shows (it can't load one itself).
    @ObservationIgnored private(set) var previewNote: ConversationNote?
    /// The Dictations list a headless render shows.
    @ObservationIgnored private(set) var previewDictations: [DictationDay]?
    /// The day's conversations a headless render shows.
    @ObservationIgnored private(set) var previewDay: [ConversationNote]?

    /// Sample state for headless renders of the views: the test home's settings and notes, a real note's
    /// lines as the live transcript (with the words list, like live lines) in a conversation that began 4 minutes
    /// ago. Nothing starts and nothing is written; there's no mic. `day`: the open day's conversations.
    /// `firstRun`: as on a new Mac, before the models are downloaded.
    init(
        previewOf note: ConversationNote?, names: [NoteName], selection: SidebarItem, day: [ConversationNote]? = nil,
        firstRun: Bool = false
    ) {
        settings = Settings.load()
        fixer = WordFixer(settings.words)
        previewDictations = DictationDay.load(notes: settings.notesURL)
        library.show(names, dictationDays: previewDictations?.map(\.day) ?? [])
        self.selection = selection
        if !firstRun {
            live = .ready
            conversationStartedAt = Date().addingTimeInterval(-240)
        }
        previewDay = day
        mic = .running
        micAllowed = true
        lagMs = 238
        level = -30
        previewNote = note
        var slots: [String: Int] = [:]
        showLines(
            (note?.lines ?? []).enumerated().map { i, line in
                let slot = slots[line.speaker] ?? slots.count
                slots[line.speaker] = slot
                return LiveLine(id: i, speaker: slot, settled: true, text: line.text, start: line.offset, end: line.offset + 3)
            })
        lines = currentLines  // a headless render has no window to wait for
        speakersActive = true
    }

    // MARK: state for the menu bar and the window

    var isPaused: Bool { settings.isPaused() }

    /// What's wrong, in plain words, if anything.
    var problem: String? {
        if micDenied { return "No microphone access. Allow Sona in System Settings, Privacy & Security, Microphone." }
        if case .problem(let why) = mic { return why }
        if case .failed(let why) = live { return why }
        if settings.alwaysOn, notesFailed, let why = notesSetup { return why }
        return nil
    }

    /// Off: always-on is off, so the mic only opens for dictation.
    var menuIcon: MenuBarIcon.State {
        if !settings.onboarded { return .notSetUp }
        if problem != nil { return .problem }
        if isPaused { return .paused }
        if hearing { return .hearing }
        if case .loading = live { return .loading }
        if !settings.alwaysOn { return .off }
        return .idle
    }

    var statusLine: String {
        if !settings.onboarded { return "Not listening yet: finish setting up" }
        if let problem { return "Problem: \(problem)" }
        if let until = settings.pausedUntil, isPaused { return "Paused until \(Self.when(until))" }
        if case .loading(let p, let text) = live { return p > 0.01 ? "\(text) \(Int(p * 100))%" : text }
        guard settings.alwaysOn else {
            return settings.dictation ? "Always-on is off. Hold \(settings.dictationKey.title) to dictate." : "Always-on and dictation are off"
        }
        var parts: [String] = []
        if hearing {
            parts.append("Hearing someone")
        } else if let started = conversationStartedAt {
            parts.append("In a conversation since \(NoteWriter.timeString(started, "HH:mm"))")
        } else {
            parts.append(mic == .running ? "Listening" : "Starting the microphone...")
        }
        if processing.busy { parts.append(processing.pending > 1 ? "writing \(processing.pending) notes" : "writing a note") }
        if let setup = notesSetup { parts.append(setup) }
        return parts.joined(separator: ", ")
    }

    /// "15:30", or "tomorrow 06:00", or "Fri 06:00".
    static func when(_ date: Date) -> String {
        let cal = Calendar.current
        if cal.isDateInToday(date) { return NoteWriter.timeString(date, "HH:mm") }
        if cal.isDateInTomorrow(date) { return "tomorrow " + NoteWriter.timeString(date, "HH:mm") }
        return NoteWriter.timeString(date, "EEE HH:mm")
    }

    /// "Speaker 2" for the room's slot 1; the Mac's voices (slots from `LiveLine.macSlot`) are "Mac audio" or
    /// "Mac audio 2", never a person.
    static func speakerName(_ slot: Int?) -> String {
        guard let slot else { return "Someone" }
        if slot == LiveLine.macSlot { return Tracks.macLabel }
        if slot > LiveLine.macSlot { return Tracks.macName(slot - LiveLine.macSlot - 1, of: 2) }
        return "Speaker \(slot + 1)"
    }

    // MARK: starting

    func start() {
        dictation.blocked = { [weak self] in self?.dictationBlocked }
        dictation.onHold = { [weak self] held in self?.dictationHeld(held) }
        dictation.onPaste = { [weak self] text in self?.pasted(text) }
        dictation.fixer = fixer
        dictation.configure(enabled: settings.dictation, key: settings.dictationKey)
        if TestRun.isOn { dictation.showsPill = false }
        // AI access off: nothing the AI side reads is left lying around (the live transcript, the search index).
        if !settings.mcp { feedQueue.async { LiveFeed.remove(); SearchIndex.discard() } }
        let workspace = NSWorkspace.shared.notificationCenter
        workspace.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.asleep = true
                self?.updateMac()
                self?.recorder?.close("Mac going to sleep")
            }
        }
        workspace.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                Log.note("woke up")
                self?.asleep = false
                self?.micDriver?.woke()
                self?.recorder?.reset()
                self?.updateMac()
            }
        }
        let timer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        timer.tolerance = 1
        heartbeat = timer
        library.refresh(root: settings.conversationsURL)
        writeStatus()
        // Test runs (LIVE_FILE, no window) can't show the first-run screen: they go straight on.
        if settings.onboarded || TestRun.isOn { begin() } else { Log.note("waiting for the first-run screen") }
    }

    /// Everything that listens, and Open at login: the mic, dictation's key, recording. Only once the first-run
    /// screen is done.
    private func begin() {
        guard !begun else { return }
        begun = true
        checkMicAccess()
        if !TestRun.isOn {
            dictation.install(prompt: !skipAccessibilityPrompt)
            loginMessage = LoginItem.apply(settings.launchAtLogin)
        }
        // Recording starts while the live models load, unless the voice detector they bring isn't on disk yet.
        let live = loadLive()
        Task {
            if !Models.vadOnDisk { await live.value }
            await syncRecorder()
        }
        updateMic()
        startPhoneImport()
    }

    /// Loads the live set (Parakeet Unified, Nemotron 3, Silero: about 960 MB to download the first time). The
    /// first-run screen can start it early; nothing listens until `begin`. After a failed load (no network for
    /// the first download, say) it tries again.
    @discardableResult
    func loadLive() -> Task<Void, Never> {
        if let liveTask, !liveLoadFailed { return liveTask }
        live = .loading(0, "Loading the speech model...")
        let task = Task { await prepareLive() }
        liveTask = task
        liveStarted = true
        return task
    }

    /// The live set didn't load (as opposed to a session that stopped later).
    var liveLoadFailed: Bool {
        if case .failed = live, engine == nil { return true }
        return false
    }

    /// The first-run screen's Start: how to listen, then everything begins.
    func finishFirstRun(alwaysOn: Bool, aiAccess: Bool, openAtLogin: Bool, macAudio: Bool = false) {
        update {
            $0.onboarded = true
            $0.alwaysOn = alwaysOn
            $0.mcp = aiAccess
            $0.launchAtLogin = openAtLogin
            $0.macAudio = macAudio
        }
        Log.note(
            "first run done (always-on \(alwaysOn ? "on" : "off"), AI access \(aiAccess ? "on" : "off"), open at login "
                + "\(openAtLogin ? "on" : "off"), Mac audio \(macAudio ? "on" : "off"))")
        skipAccessibilityPrompt = true
        begin()
    }

    /// Test runs never use (or ask for) the real mic: `LIVE_FILE` stands in for it, or there's no audio at all.
    private func checkMicAccess() {
        guard !TestRun.isOn else { return }
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            micDenied = false
            if !micAllowed {
                micAllowed = true
                updateMic()
            }
        case .notDetermined:
            Task {
                let granted = await AVCaptureDevice.requestAccess(for: .audio)
                micAllowed = granted
                micDenied = !granted
                updateMic()
            }
        default:
            micAllowed = false
            micDenied = true
            updateMic()
        }
    }

    /// The live set: Parakeet Unified, Nemotron 3 speakers, Silero for the voice gate. Loaded from disk with no
    /// network; only if that fails (the first run) is it downloaded.
    private func prepareLive() async {
        let engine = UnifiedEngine()
        let speakers = settings.speakers
        let progress: @Sendable (Double, String) -> Void = { p, text in
            DispatchQueue.main.async {
                MainActor.assumeIsolated { if case .loading = self.live { self.live = .loading(p, text) } }
            }
        }
        do {
            let diarizer: LiveDiarizer?
            do {
                diarizer = try await Self.loadLive(engine, speakers: speakers, strict: true, progress: progress)
            } catch {
                Log.note("live models aren't all on disk (\(Log.describe(error))), downloading")
                Models.allowDownloads(true)
                defer { Models.allowDownloads(false) }
                diarizer = try await Self.loadLive(engine, speakers: speakers, strict: false, progress: progress)
            }
            self.engine = engine
            sharedEngine = SharedEngine(engine)
            self.diarizer = diarizer
            // Speakers may have been turned on while it loaded.
            if settings.speakers, diarizer == nil { await prepareDiarizer(duringLiveLoad: true) }
            startSession()
            await loadClipModel()
        } catch {
            Log.note("live model didn't load: \(Log.describe(error))")
            live = .failed("The speech model didn't load (\(error.localizedDescription))")
        }
    }

    /// Dictation's own copy of the notes model, for the hold's whole clip, once it's on disk (it's downloaded with
    /// the notes models). Without it dictation pastes the live words. `LIVE_DICTATE_CLIP=off` leaves it out.
    private func loadClipModel() async {
        guard dictation.clips == nil, settings.dictation, Models.isReady(model: settings.model),
            ProcessInfo.processInfo.environment["LIVE_DICTATE_CLIP"] != "off"
        else { return }
        let t0 = hostNow()
        do {
            dictation.clips = try await ClipTranscriber.load(model: settings.model)
            Log.note(String(format: "dictation's clip model loaded in %.1f s", hostNow() - t0))
        } catch {
            Log.note("dictation's clip model didn't load: \(Log.describe(error))")
        }
    }

    /// The speaker model, from disk or (it wasn't needed before) downloaded now. Downloads go one at a time:
    /// after the live set's (unless this is part of it), and never during the notes models'.
    private func prepareDiarizer(duringLiveLoad: Bool = false) async {
        let d = LiveDiarizer()
        do {
            do { try await d.prepare { _, _ in } } catch {
                if !duringLiveLoad { await liveTask?.value }
                // (During the live load a notes download is only waiting for it.)
                guard duringLiveLoad || !downloadingNotes else { throw error }
                Models.allowDownloads(true)
                defer { Models.allowDownloads(false) }
                try await d.prepare { _, _ in }
            }
            diarizer = d
        } catch {
            Log.note("speaker model didn't load: \(Log.describe(error))")
        }
    }

    /// `strict`: every part must load (a miss means a download is needed). Otherwise only the engine must;
    /// without the speaker model or the voice detector, words still flow.
    nonisolated private static func loadLive(
        _ engine: UnifiedEngine, speakers: Bool, strict: Bool, progress: @escaping @Sendable (Double, String) -> Void
    ) async throws -> LiveDiarizer? {
        try await engine.prepare(progress: progress)
        var diarizer: LiveDiarizer?
        if speakers {
            let d = LiveDiarizer()
            do {
                try await d.prepare(progress: progress)
                diarizer = d
            } catch {
                if strict { throw error }
                Log.note("speaker model didn't load: \(Log.describe(error))")
            }
        }
        do { _ = try await VoiceGate.loadModel() } catch { if strict { throw error } }
        return diarizer
    }

    private func startSession() {
        guard let sharedEngine, session == nil else { return }
        let relay = RelaySource()
        let session = LiveSession(engine: sharedEngine.track(.mic), source: relay, diarizer: settings.speakers ? diarizer : nil)
        session.voiceGate = ProcessInfo.processInfo.environment["LIVE_GATE"] != "off"
        self.session = session
        self.relay = relay
        transcript = LiveTranscript()
        echoes = []
        macTranscript = LiveTranscript()
        pastMacLines = []
        pastMacWords = []
        wallClock = WallClock()
        showLines([])
        speakerLog = SpeakerLog()
        speakersActive = session.diarizer != nil
        speakerLogSince = speakersActive ? Date() : .distantFuture
        lag = LatencyStats(keepLast: 300)
        live = .ready
        sessionStarted = Date()
        Log.note("live transcript ready (speakers \(speakersActive ? "on" : "off"), voice gate \(session.voiceGate ? "on" : "off"))")
        micDriver?.setRelay(relay)
        dictation.attach(session, relay: relay)
        sessionTask = Task {
            do {
                try await session.run { update in
                    DispatchQueue.main.async { MainActor.assumeIsolated { self.apply(update, from: session) } }
                }
            } catch {
                Log.note("live session ended: \(Log.describe(error))")
                if self.session === session { self.sessionFailed(error) }
            }
            self.dictation.detach(session)
        }
        updateMic()
        if macAudio == .on { startMacSession() }
        publish(force: true)
    }

    /// The engine failed mid-session (a Neural Engine hiccup, say): say so, and start a new session after
    /// 10 s, 20 s, 40 s ... (10 min at most). A session that ran a minute starts the count over.
    private func sessionFailed(_ error: Error) {
        live = .failed("The live transcript stopped (\(error.localizedDescription)). Trying again.")
        if Date().timeIntervalSince(sessionStarted) > 60 { sessionFailures = 0 }
        sessionFailures += 1
        let delay = min(10 * pow(2, Double(sessionFailures - 1)), 600)
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            MainActor.assumeIsolated { self?.restartSession() }
        }
    }

    /// A new session (speakers turned on or off, or after a failure); the mic stays as it is. Restarts run one
    /// after another, so two sessions never share the engine.
    private func restartSession() {
        guard engine != nil else { return }  // still loading: it reads the setting when it's done
        let before = restarting
        restarting = Task {
            await before?.value
            await stopSession()
            if settings.speakers, diarizer == nil { await prepareDiarizer() }
            startSession()
        }
    }

    /// Ends the current session and waits until it has let go of the engine.
    private func stopSession() async {
        await stopMacSession()
        if let old = session {
            session = nil
            micDriver?.setRelay(nil)
            relay?.stop()
            relay = nil
            dictation.detach(old)
        }
        let task = sessionTask
        sessionTask = nil
        await task?.value
    }

    // MARK: this Mac's audio

    private func macAudioChanged(_ state: MacAudioDriver.State) {
        let was = macAudio
        macAudio = state
        if state == .on, was != .on {
            startMacSession()
        } else if state == .off, was != .off {
            // Let go of it now, so audio coming back at once starts a new session; the old one finishes on its own.
            _ = endMacSession()
        }
    }

    /// Hear this Mac's audio while the switch is on and always-on is listening (the driver then taps only while
    /// something plays).
    private func updateMac(listening: Bool? = nil) {
        let ready = TestRun.file != nil ? session != nil : recorder != nil || session != nil
        let listening = listening ?? (begun && !isPaused && micAllowed && settings.alwaysOn && ready)
        macDriver?.update(
            // A test run never taps this Mac: only `LIVE_FILE_MAC` stands in for it.
            switchOn: settings.macAudio && (!TestRun.isOn || TestRun.fileMac != nil), listening: listening,
            paused: isPaused, asleep: asleep)
    }

    /// The Mac track's live session: the same engine (taking turns with the mic), the same speaker model, its own
    /// voice gate and clock.
    private func startMacSession() {
        guard macSession == nil, session != nil, let sharedEngine else { return }
        // What the last one heard stays, on the mic's clock (the new one has its own).
        let (lines, words) = macOnMicClock()
        pastMacLines = Array((pastMacLines + lines).suffix(2_000))
        pastMacWords = Array((pastMacWords + words).suffix(8_000))
        let relay = RelaySource()
        let mac = LiveSession(engine: sharedEngine.track(.mac), source: relay, diarizer: speakersActive ? diarizer?.sibling() : nil)
        mac.voiceGate = ProcessInfo.processInfo.environment["LIVE_GATE"] != "off"
        macSession = mac
        macRelay = relay
        macTranscript = LiveTranscript()
        macSlots = []
        macDriver?.setRelay(relay)
        Log.note("Mac audio live transcript on (speakers \(mac.diarizer != nil ? "on" : "off"))")
        macSessionTask = Task {
            do {
                try await mac.run { update in
                    DispatchQueue.main.async { MainActor.assumeIsolated { self.applyMac(update, from: mac) } }
                }
            } catch {
                Log.note("Mac audio live session ended: \(Log.describe(error))")
            }
        }
    }

    /// Ends the Mac track's session and waits until it has let go of the engine.
    private func stopMacSession() async {
        await endMacSession()?.value
    }

    /// Ends the Mac track's session; the task finishes once it has let go of the engine.
    private func endMacSession() -> Task<Void, Never>? {
        guard let mac = macSession else { return nil }
        macSession = nil
        macDriver?.setRelay(nil)
        macRelay?.stop()
        let task = macSessionTask
        macSessionTask = nil
        mac.cancel()
        // Its words stay on screen, mapped through its relay's clock, until the next session.
        return task
    }

    private func applyMac(_ update: LiveUpdate, from mac: LiveSession) {
        guard mac === macSession, !update.tokens.isEmpty || !update.speakerFrames.isEmpty || update.speakersFailed else { return }
        if let first = update.tokens.first {
            heardWords()
            // Like the mic's words, these date the transcript (the room may be silent while a video plays).
            if let host = macRelay?.clock.hostTime(atSeconds: first.start), let s = relay?.clock.seconds(atHost: host) {
                wallClock.mark(s, at: Date().addingTimeInterval(host - hostNow()))
            }
        }
        macTranscript.add(update.tokens)
        macTranscript.speakers.append(update.speakerFrames)
        macTranscript.resolveSpeakers()
        refreshLines()
        publish()
    }

    /// The Mac's words in the mic session's seconds (both clocks are host time), for the merged lines and the echo
    /// check. Nil before the mic's clock knows that time.
    private func micSeconds(macSeconds s: Double) -> Double? {
        guard let macRelay, let relay, let host = macRelay.clock.hostTime(atSeconds: s) else { return nil }
        return relay.clock.seconds(atHost: host)
    }

    /// The current Mac session's lines and words on the mic's clock, its voices labelled.
    private func macOnMicClock(since horizon: Double = -.infinity) -> (lines: [LiveLine], words: [EchoFilter.Timed]) {
        guard !macTranscript.words.isEmpty else { return ([], []) }
        var words: [EchoFilter.Timed] = []
        for w in macTranscript.words.reversed() {
            guard let t = micSeconds(macSeconds: w.start) else { continue }
            if t < horizon { break }
            words.append(EchoFilter.Timed(w.text, t))
        }
        words.reverse()
        for w in macTranscript.words { if let s = w.speaker { macSlots.insert(s) } }
        let several = macSlots.count > 1
        // Ids go on from the earlier sessions', so they never clash.
        let base = LiveLine.macIDs + (pastMacLines.last.map { $0.id - LiveLine.macIDs + 1 } ?? 0)
        var lines: [LiveLine] = []
        for line in macTranscript.lines() {
            guard let start = micSeconds(macSeconds: line.start), let end = micSeconds(macSeconds: line.end) else { continue }
            let slot = several ? line.speaker.map { LiveLine.macSlot + 1 + $0 } ?? LiveLine.macSlot : LiveLine.macSlot
            lines.append(LiveLine(id: base + line.id, speaker: slot, settled: line.settled || !speakersActive, text: line.text, start: start, end: end))
        }
        return (lines, words)
    }

    /// Now's lines: the mic's (without its echoes of the Mac) and the Mac's, merged by time. With no Mac audio
    /// heard this session, just the mic's.
    private func refreshLines() {
        guard !macTranscript.words.isEmpty || !pastMacLines.isEmpty else { return showLines(transcript.lines()) }
        // Echo check over the last minute of mic words (older ones keep what they had).
        let horizon = (transcript.words.last?.start ?? 0) - 60
        let (macLines, macWords) = macOnMicClock(since: horizon - EchoFilter.twinSeconds)
        let from = transcript.words.firstIndex { $0.start >= horizon } ?? transcript.words.count
        let recent = transcript.words[from...]
        let flags = EchoFilter.echoes(
            mic: recent.map { EchoFilter.Timed($0.text, $0.start) },
            mac: pastMacWords.filter { $0.start >= horizon - EchoFilter.twinSeconds } + macWords)
        for (k, i) in recent.indices.enumerated() {
            let absolute = i + transcript.dropped
            if flags[k] { echoes.insert(absolute) } else { echoes.remove(absolute) }
        }
        showLines(LiveMerge.lines(mic: transcript.lines(hiding: echoes), mac: pastMacLines + macLines))
    }

    // MARK: the live transcript

    private func apply(_ update: LiveUpdate, from session: LiveSession) {
        guard session === self.session, let relay else { return }  // a replaced session's last words
        let now = hostNow()
        if update.speakersFailed {
            speakersActive = false
            refreshLines()
        }
        if let first = update.tokens.first {
            heardWords()
            // Moments after the words were said, so this wall-clock time is right even if the Mac sleeps later.
            if let host = relay.clock.hostTime(atSeconds: first.start) {
                wallClock.mark(first.start, at: Date().addingTimeInterval(host - now))
            }
        }
        dictation.feed(update.tokens)
        if !update.tokens.isEmpty || !update.speakerFrames.isEmpty {
            transcript.add(update.tokens)
            transcript.speakers.append(update.speakerFrames)
            if speakersActive { logSpeakers(transcript.resolveSpeakers(), clock: relay.clock, now: now) }
            refreshLines()
        }
        for s in update.heard {
            if let ms = relay.clock.lagMs(atSeconds: s, now: now) { lag.add(ms) }
        }
        publish()
    }

    /// The lines Now, Copy and now.json show: the transcript's, with the words list applied (only to lines that
    /// changed since last time).
    private func showLines(_ raw: [LiveLine]) {
        var shown = raw
        if !fixer.isEmpty {
            for i in shown.indices {
                let same = i < rawLines.count && i < currentLines.count && rawLines[i].id == raw[i].id && rawLines[i].text == raw[i].text
                shown[i].text = same ? currentLines[i].text : fixer.apply(raw[i].text)
            }
        }
        rawLines = raw
        currentLines = shown
        linesChanged = true
        showLinesSoon()
    }

    /// Hands the latest lines to Now at most 4 times a second: every token used to redraw the whole list, many
    /// times a second while people talk. Nothing while the window can't be seen; it catches up when it can.
    private func showLinesSoon() {
        guard windowVisible, linesChanged, linesPending == nil else { return }
        let wait = linesShownAt + 0.25 - ProcessInfo.processInfo.systemUptime
        guard wait > 0 else { return showLinesNow() }
        let item = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated {
                self?.linesPending = nil
                self?.showLinesNow()
            }
        }
        linesPending = item
        DispatchQueue.main.asyncAfter(deadline: .now() + wait, execute: item)
    }

    private func showLinesNow() {
        linesPending?.cancel()
        linesPending = nil
        guard windowVisible, linesChanged else { return }
        linesChanged = false
        linesShownAt = ProcessInfo.processInfo.systemUptime
        lines = currentLines
    }

    /// Who said each newly labelled word, in wall-clock time, for the speaker hint.
    private func logSpeakers(_ resolved: Range<Int>, clock: AudioClock, now: Double) {
        let date = Date()
        for i in resolved {
            let w = transcript.words[i - transcript.dropped]
            guard let slot = w.speaker, let host = clock.hostTime(atSeconds: w.start) else { continue }
            speakerLog.add(slot: slot, at: date.addingTimeInterval(host - now))
        }
    }

    /// `hearing` for 2 s after the latest words. One timer per stretch of talk, not one per update: it checks when
    /// it fires and waits on if words came meanwhile.
    private func heardWords() {
        heardAt = ProcessInfo.processInfo.systemUptime
        guard !hearing else { return }
        hearing = true
        scheduleHearingOff(after: 2)
    }

    private func scheduleHearingOff(after seconds: Double) {
        hearingOff?.cancel()
        let item = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.hearing else { return }
                let left = self.heardAt + 2 - ProcessInfo.processInfo.systemUptime
                if left > 0.01 { self.scheduleHearingOff(after: left) } else { self.hearing = false }
            }
        }
        hearingOff = item
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds, execute: item)
    }

    /// Shown with who said it: with speakers on, and the Mac's lines always (they're never a person).
    func labelled(_ line: LiveLine) -> Bool { speakersActive || (line.speaker ?? 0) >= LiveLine.macSlot }

    func copyNow() {
        let text = currentLines.map { (labelled($0) ? "\(Self.speakerName($0.speaker)): " : "") + $0.text }.joined(separator: "\n\n")
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    /// Writes the last ~10 minutes to `Live/now.json` for the MCP `live` tool: at most 3 times a second and only
    /// when something changed, but the latest state always lands. `force` writes now (the 15 s heartbeat). Only
    /// with AI access on, and words only while always-on recording is on and not paused.
    private func publish(force: Bool = false) {
        guard settings.mcp else { return }
        let wait = lastFeedBuild + 1.0 / 3 - ProcessInfo.processInfo.systemUptime
        if !force, wait > 0 {
            if feedPending == nil {
                let item = DispatchWorkItem { [weak self] in
                    MainActor.assumeIsolated {
                        self?.feedPending = nil
                        self?.publish()
                    }
                }
                feedPending = item
                DispatchQueue.main.asyncAfter(deadline: .now() + wait, execute: item)
            }
            return
        }
        feedPending?.cancel()
        feedPending = nil
        lastFeedBuild = ProcessInfo.processInfo.systemUptime
        let sharing = settings.alwaysOn && !isPaused && session != nil
        var feedLines: [LiveFeed.Line] = []
        if sharing {
            let now = Date(), wall = wallClock
            func date(_ s: Double) -> Date { wall.date(atSeconds: s) ?? now }
            feedLines = currentLines.suffix(400).filter { date($0.end) > now.addingTimeInterval(-600) }.map { line in
                LiveFeed.Line(
                    speaker: labelled(line) ? Self.speakerName(line.speaker) : nil, settled: line.settled || !speakersActive,
                    start: date(line.start), end: date(line.end + 0.24), text: line.text)
            }
        }
        let feed = LiveFeed(listening: sharing && mic == .running, engine: "Parakeet Unified 0.6B", speakers: speakersActive, lines: feedLines)
        if !force, let last = lastFeed, feed.sameContent(as: last) { return }
        lastFeed = feed
        feedQueue.async { feed.write() }
    }

    // MARK: the mic

    /// Open while listening all day, or (always-on off) while the dictation key is held and 2 s after. Never
    /// before the first-run screen is done.
    private func updateMic() {
        let dictating = holding || hostNow() < lingerUntil
        // A test file is played once the live transcript is ready too, so all of it is heard live.
        let ready = TestRun.file != nil ? session != nil : recorder != nil || session != nil
        let want = begun && !isPaused && micAllowed && (settings.alwaysOn && ready || dictating && session != nil)
        micDriver?.setWanted(want)
        updateMac(listening: want && settings.alwaysOn)
    }

    /// A dictation was pasted. With always-on off it goes in the Dictations list (with it on, it's in the notes).
    private func pasted(_ text: String) {
        guard !settings.alwaysOn else { return }
        let notes = settings.notesURL, at = Date()
        feedQueue.async {
            do { try Dictations.append(text, at: at, notes: notes) } catch { Log.note("couldn't save a dictation: \(Log.describe(error))") }
            DispatchQueue.main.async { MainActor.assumeIsolated { self.library.dictationsChanged(notes: notes) } }
        }
    }

    private var dictationBlocked: String? {
        if isPaused { return "Paused" }
        if micDenied { return "No microphone access" }
        if case .failed = live { return "The speech model didn't load" }
        if session == nil { return "Loading the speech model..." }
        return nil
    }

    private func dictationHeld(_ held: Bool) {
        holding = held
        if !held {
            // Fn-only mode: keep the mic open a little after a dictation, so the next one starts instantly
            // (opening the mic takes 0.1-0.5 s, more after wake). Then it closes again.
            lingerUntil = hostNow() + 30
            DispatchQueue.main.asyncAfter(deadline: .now() + 30.05) { [weak self] in MainActor.assumeIsolated { self?.updateMic() } }
        }
        updateMic()
    }

    // MARK: always-on notes

    /// The spool and processor, made once (the first time always-on is on): they outlive the Listener, so a
    /// conversation is never worked on twice and what was heard before always-on went off still gets its note.
    private func notesPipeline() -> (spool: Spool, processor: Processor) {
        if let notes { return notes }
        let spool = Spool()
        let processor = Processor(
            spool: spool, settings: settings,
            onState: { state in DispatchQueue.main.async { MainActor.assumeIsolated { self.processingChanged(state) } } })
        notes = (spool, processor)
        return (spool, processor)
    }

    /// Starts the Listener when always-on is on, stops it when it's off.
    private func syncRecorder() async {
        if settings.alwaysOn {
            guard recorder == nil, !recorderStarting else { return }
            recorderStarting = true
            // Turned off and straight back on: let the old Listener close its conversation first, or the new
            // one could start on the same spool while that close is still queued.
            await recorderStopping?.value
            let (spool, processor) = notesPipeline()
            let made: Recorder
            do {
                made = try await Recorder.make(settings: settings, spool: spool) { event in self.recorderEvent(event) }
            } catch {
                recorderStarting = false
                Log.note("always-on recording didn't start: \(Log.describe(error))")
                notesFailed = true
                notesSetup = "Recording didn't start (\(error.localizedDescription)). Trying again in a few minutes."
                return
            }
            recorderStarting = false
            guard settings.alwaysOn, recorder == nil else { return await made.finish(reason: "always-on turned off") }
            recorder = made
            recording = true
            micDriver?.setRecorder(made.input)
            macDriver?.setRecorder(made.macInput)
            updateMic()
            Log.note("always-on recording started")
            await processor.recover()
            if !Models.isReady(model: settings.model) { await downloadNotesModels() }
            if Models.isReady(model: settings.model), settings.alwaysOn { try? await processor.warmUp() }
        } else if let r = recorder {
            recorder = nil
            recording = false
            micDriver?.setRecorder(nil)
            macDriver?.setRecorder(nil)
            conversationStartedAt = nil
            updateMic()
            Log.note("always-on recording stopped")
            // What it heard so far still becomes a note; then the models are let go.
            let stopping = Task { await r.finish(reason: "always-on turned off") }
            recorderStopping = stopping
            await stopping.value
            recorderStopping = nil
            if let processor = notes?.processor {
                Task {
                    await processor.waitUntilIdle()
                    if !settings.alwaysOn { await processor.unload() }
                }
            }
            // Turned back on meanwhile.
            if settings.alwaysOn { await syncRecorder() }
        }
    }

    /// Parakeet TDT and the offline diarizer (about 465 MB), only needed for always-on notes. After the live set:
    /// downloads switch FluidAudio's one offline flag, so two at once would cut each other short.
    private func downloadNotesModels() async {
        guard !downloadingNotes else { return }
        downloadingNotes = true
        defer { downloadingNotes = false }
        await liveTask?.value
        notesFailed = false
        notesSetup = "downloading the notes models"
        do {
            try await Models.prepare(model: settings.model) { p, _ in
                DispatchQueue.main.async {
                    MainActor.assumeIsolated { self.notesSetup = "downloading the notes models, \(Int(p * 100))%" }
                }
            }
            notesSetup = nil
            await loadClipModel()
            await notes?.processor.recover()
        } catch {
            Log.note("notes models didn't download: \(Log.describe(error))")
            notesFailed = true
            notesSetup = "The notes models didn't download (\(error.localizedDescription)). Trying again in a few minutes."
        }
    }

    /// The live pass's count of who spoke during a finished conversation, when it heard 2 or more: exact if it
    /// covered the conversation (all but its first 3 s or 5%, say right after launch), else "at least" (it may
    /// have missed someone, and too few would merge people in the note).
    private func hint(for entry: SpoolEntry) -> SpeakerHint? {
        // With this Mac playing, the room's count also has the Mac's voices heard through the speakers.
        guard speakersActive, (entry.mac?.speechSeconds ?? 0) < 1 else { return nil }
        let end = entry.startedAt.addingTimeInterval(entry.speechEnd)
        let n = min(speakerLog.count(from: entry.startedAt, to: end), SpeakerHint.most)
        guard n >= 2 else { return nil }
        let missed = speakerLogSince.timeIntervalSince(entry.startedAt)
        return missed <= max(3, entry.speechEnd * 0.05) ? .exactly(n) : SpeakerHint(min: n)
    }

    private func recorderEvent(_ event: Listener.Event) {
        switch event {
        case .opened(let at):
            conversationStartedAt = at
        case .closed(let entry):
            conversationStartedAt = nil
            guard let processor = notes?.processor else { return }
            let hint = hint(for: entry)
            if quitting {
                // No time to transcribe it now: it's in the spool, with its hint, for next launch.
                lastHint = Task { await processor.remember(hint, for: entry.id) }
            } else {
                Task { await processor.enqueue(entry.id, speakers: hint) }
            }
        case .discarded:
            conversationStartedAt = nil
        case .speech:
            break
        }
    }

    private func processingChanged(_ state: Processor.State) {
        let wrote = state.lastNote != nil && state.lastNote != processing.lastNote
        processing = state
        if wrote { library.refresh(root: settings.conversationsURL) }
    }

    // MARK: the iPhone's notes

    /// Copies the iPhone's notes (from iCloud Drive) into the notes folder at launch and then every minute. It
    /// does nothing while none of the iPhone's folders is on this Mac, and costs a directory listing and a stat
    /// per file when nothing changed. In a test home it only looks at `PhoneInbox` there.
    private func startPhoneImport() {
        guard phoneImport == nil else { return }
        phoneImport = Task { [weak self] in
            while !Task.isCancelled {
                await self?.importPhoneNotes()
                try? await Task.sleep(for: .seconds(60))
            }
        }
    }

    /// One pass, off the main thread (the copying, hashing and listing are in the detached task).
    private func importPhoneNotes() async {
        // Unreadable settings give the default notes folder, which may not be the user's: the iPhone's notes (ones
        // deleted from the user's folder too) would be copied into it. Not until a setting is saved.
        guard !settingsUnreadable else { return }
        let root = settings.conversationsURL
        let summary = await Task.detached(priority: .utility) {
            PhoneImport.run(to: root, statePath: PhoneImport.defaultStatePath)
        }.value
        // The sidebar lists file names, so it only needs to hear about new notes; an open one is read again if
        // its file was replaced.
        if summary.updated > 0 {
            library.changed(root: root)
        } else if summary.imported > 0 {
            library.refresh(root: root)
        }
        // Titles for the iPhone's notes it couldn't title itself, written beside them in iCloud for the iPhone to
        // fold in. Off the main thread, a few at a time; nothing before macOS 26 or without Apple Intelligence.
        // Those titles go into this Mac's copies too, so the lists read them again.
        let titled = await Task.detached(priority: .utility) { await MacTitles.run(macConversations: root) }.value
        if titled > 0 { library.changed(root: root) }
    }

    // MARK: pause, settings, quit

    func pause(until: Date) {
        update { $0.pausedUntil = until }
        recorder?.close("paused")
        hearing = false
        Log.note("paused until \(NoteWriter.iso(until))")
    }

    func resume() {
        guard settings.pausedUntil != nil else { return }
        update { $0.pausedUntil = nil }
        recorder?.reset()
        Log.note("resumed")
    }

    /// "Delete the last N minutes", for good (not the Trash): the open conversation's audio from then on (it's
    /// closed there, or dropped if it started after), conversations waiting to become notes, notes and their
    /// lines, the live transcript and now.json, the Dictations list (up to the click: one pasted while the
    /// rest runs stays), the last dictation kept in memory, and dictations saved for debugging.
    func deleteLast(minutes: Int) {
        let now = Date()
        let cut = now.addingTimeInterval(-Double(minutes) * 60)
        Log.note("deleting the last \(minutes) min")
        forgetLive(from: cut)
        dictation.forget(from: cut)
        let debugFiles = Dictation.forgetDebugFiles(from: cut)
        let root = settings.conversationsURL, notesURL = settings.notesURL, queue = feedQueue
        // The spool can hold conversations with always-on off too (from before it went off), so the processor
        // (no models loaded) is made if it isn't there yet.
        let recorder = recorder, stopping = recorderStopping, processor = notesPipeline().processor
        Task {
            await recorder?.forget(from: cut)
            // Always-on just went off: its last conversation is still being closed. Let it, then cut it with the rest.
            await stopping?.value
            let notes = await processor.forget(from: cut)
            let dictations = await withCheckedContinuation { done in
                queue.async { done.resume(returning: Dictations.forget(from: cut, to: now, notes: notesURL)) }
            }
            if notes.changed > 0 { SearchIndex.discard() }
            library.changed(root: root)
            Log.note(
                "deleted the last \(minutes) min: \(notes.deleted) note(s) deleted, \(notes.trimmed) cut, "
                    + "\(notes.failed) couldn't be changed, \(dictations) dictation(s), \(debugFiles) debugging file(s)")
            if notes.failed > 0 {
                let alert = NSAlert()
                alert.messageText = "Some notes couldn't be changed"
                alert.informativeText =
                    "\(notes.failed == 1 ? "1 note" : "\(notes.failed) notes") from that time couldn't be written again, so "
                    + "they still have what was said then. Is the disk full? Try again, or delete them in Finder."
                NSApp.activate(ignoringOtherApps: true)
                alert.runModal()
            }
        }
    }

    /// Now and now.json without the words said from `cut` on, including words still being decoded now: they arrive
    /// later, and are dropped for the rest of this session if they began between the cut and the audio heard by now
    /// (with the mic closed, where it stopped).
    private func forgetLive(from cut: Date) {
        let wall = wallClock, now = Date()
        let first = transcript.words.firstIndex(where: { (wall.date(atSeconds: $0.start) ?? now) >= cut }) ?? transcript.words.count
        var heard = relay?.endSeconds ?? 0
        if let relay, relay.isFlowing, let seconds = relay.clock.seconds(atHost: hostNow()) { heard = max(heard, seconds) }
        // The wall clock is marked only when words come: with none since a gap (asleep, paused, a closed mic) it runs on
        // past where the audio picked up again. The audio's own clock knows where that was; the earlier of the two.
        var from = wall.seconds(at: cut) ?? 0
        if let relay, let seconds = relay.clock.seconds(atHost: hostNow() - now.timeIntervalSince(cut)) { from = min(from, seconds) }
        transcript.forget(from: first, during: min(from, heard)..<heard)
        // The Mac's words likewise, by their own clock.
        let cutHost = hostNow() - now.timeIntervalSince(cut)
        let macFirst = macTranscript.words.firstIndex { w in
            (micSeconds(macSeconds: w.start).flatMap { wall.date(atSeconds: $0) } ?? now) >= cut
        } ?? macTranscript.words.count
        var macHeard = macRelay?.endSeconds ?? 0
        if let macRelay, macRelay.isFlowing, let seconds = macRelay.clock.seconds(atHost: hostNow()) { macHeard = max(macHeard, seconds) }
        let macFrom = macRelay?.clock.seconds(atHost: cutHost) ?? macHeard
        macTranscript.forget(from: macFirst, during: min(macFrom, macHeard)..<macHeard)
        pastMacLines.removeAll { (wall.date(atSeconds: $0.end) ?? now) >= cut }
        pastMacWords.removeAll { (wall.date(atSeconds: $0.start) ?? now) >= cut }
        refreshLines()
        publish(force: true)
    }

    func update(_ change: (inout Settings) -> Void) {
        var new = settings
        change(&new)
        guard new != settings else { return }
        let old = settings
        settings = new
        do {
            try new.save()
            settingsUnreadable = false  // the file reads again, with what the Settings screen shows
        } catch { Log.note("couldn't save settings: \(Log.describe(error))") }
        if new.alwaysOn != old.alwaysOn {
            Log.note("always-on \(new.alwaysOn ? "on" : "off")")
            if begun { Task { await syncRecorder() } }
        }
        if new.dictation != old.dictation || new.dictationKey != old.dictationKey {
            dictation.configure(enabled: new.dictation, key: new.dictationKey)
        }
        if new.words != old.words {
            fixer = WordFixer(new.words)
            dictation.fixer = fixer
            rawLines = []
            refreshLines()
        }
        if new.mcp != old.mcp {
            Log.note("AI access \(new.mcp ? "on" : "off")")
            lastFeed = nil
            if !new.mcp { feedQueue.async { LiveFeed.remove(); SearchIndex.discard() } }
        }
        if new.speakers != old.speakers { restartSession() }
        if new.macAudio != old.macAudio {
            Log.note("Mac audio \(new.macAudio ? "on" : "off")")
            // macOS only asks for System Audio Recording when a tap first runs: ask now, not when something plays.
            if new.macAudio, !TestRun.isOn, MacAudio.supported {
                DispatchQueue.global(qos: .userInitiated).async {
                    if #available(macOS 14.2, *) { MacAudioTap.askPermission() }
                }
            }
        }
        if new.micUID != old.micUID {
            Log.note("microphone setting: \(new.micUID == nil ? "automatic" : "chosen")")
            micDriver?.setPreferred(new.micUID)
        }
        if new.notesFolder != old.notesFolder { library.refresh(root: new.conversationsURL) }
        if let processor = notes?.processor { Task { await processor.update(settings: new) } }
        if new.launchAtLogin != old.launchAtLogin, !TestRun.isOn {
            loginMessage = LoginItem.apply(new.launchAtLogin)
        }
        updateMic()
        publish(force: true)
    }

    /// Before quitting: close the open conversation so it's in the spool (it's transcribed next launch if
    /// there's no time now), and let the MCP server know.
    func finish() async {
        quitting = true
        phoneImport?.cancel()
        micDriver?.setWanted(false)
        // A clean quit mid-transcription isn't the conversation's fault: it isn't counted as a failed attempt.
        if let processor = notes?.processor { await processor.quitting() }
        if let r = recorder {
            await r.finish(reason: "quit")
            await lastHint?.value
        }
        if settings.mcp { LiveFeed(listening: false, engine: "Parakeet Unified 0.6B", speakers: false, lines: []).write() }
        AppStatus(state: "stopped").write()
    }

    /// Every 5 s: pause expiry, mic access, the MCP heartbeat (every 15 s: the MCP calls a feed older than
    /// 20 s stale), retries, status.
    private func tick() {
        if settings.pausedUntil != nil, !isPaused { resume() }
        if begun, !micAllowed, !TestRun.isOn { checkMicAccess() }
        ticks += 1
        if ticks % 3 == 0 { publish(force: true) }
        // The first download failed (offline, Wi-Fi dropped): try again every 2 minutes, not just on relaunch.
        if begun, liveLoadFailed, Date().timeIntervalSince(lastLiveRetry) > 120 {
            lastLiveRetry = Date()
            Log.note("trying the speech model download again")
            loadLive()
        }
        if begun, settings.alwaysOn, Date().timeIntervalSince(lastRetry) > 300 {
            lastRetry = Date()
            if recorder == nil {
                Task { await syncRecorder() }
            } else if !Models.isReady(model: settings.model) {
                Task { await downloadNotesModels() }
            } else if !processing.busy, let processor = notes?.processor {
                Task { await processor.recover(onlyClosed: true) }
            }
        }
        writeStatus()
    }

    // MARK: status for the MCP server and the level meter

    private func writeStatus() {
        let state: String
        var detail: String?
        if let problem {
            state = "error"
            detail = problem
        } else if isPaused {
            state = "paused"
        } else if !settings.alwaysOn {
            state = "off"
        } else if !recording {
            state = "setup"
        } else if hearing {
            state = "hearing"
        } else if processing.busy {
            state = "processing"
        } else {
            state = "listening"
        }
        let status = AppStatus(state: state, detail: detail, conversationStartedAt: conversationStartedAt, pending: processing.pending)
        let key = "\(state)|\(detail ?? "")|\(status.conversationStartedAt ?? "")|\(status.pending)"
        // On every change, and at least once a minute so readers can tell a live app from a dead one.
        guard key != lastStatus || Date().timeIntervalSince(lastStatusWrite) >= 60 else { return }
        lastStatus = key
        lastStatusWrite = Date()
        feedQueue.async { status.write() }
    }

    private func runMeter() {
        meter?.invalidate()
        meter = nil
        guard windowOpen else { return }
        meter = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                let level = self.mic == .running ? (self.micDriver?.level ?? -90) : -90
                if abs(level - self.level) > 1 { self.level = level }
                let lag = self.lag.percentile(50, window: 100)
                if lag != self.lagMs { self.lagMs = lag }
            }
        }
    }
}

/// The conversations in the notes folder for the sidebar, from file names alone (cheap enough to redo every
/// 30 s while the window is open), and the days in the Dictations list. A note is only read when it's opened.
@MainActor
@Observable
final class Library {
    private(set) var names: [NoteName] = []
    /// Days with dictations, newest first.
    private(set) var dictationDays: [String] = []
    /// Bumped when notes were deleted or cut from the app, so an open one is read again.
    private(set) var changes = 0
    /// Bumped when a dictation was added or deleted, so the Dictations list is read again.
    private(set) var dictationChanges = 0
    /// Today (`yyyy-MM-dd`), checked on every refresh so the sidebar's "today" moves on after midnight.
    private(set) var today = NoteWriter.dayString(Date())
    @ObservationIgnored private var scanning = false
    @ObservationIgnored private var again: URL?

    /// Headless renders: these, now.
    func show(_ names: [NoteName], dictationDays: [String]) {
        self.names = names
        self.dictationDays = dictationDays
    }

    /// Notes and dictations were deleted or cut: list again, and have open views read again.
    func changed(root: URL) {
        changes += 1
        dictationChanges += 1
        refresh(root: root)
    }

    /// A dictation was added: only the Dictations list (and its days, one small folder) changes.
    func dictationsChanged(notes: URL) {
        dictationChanges += 1
        let days = Dictations.days(notes: notes)
        if days != dictationDays { dictationDays = days }
    }

    /// `root`: the Conversations folder; Dictations sits next to it.
    func refresh(root: URL) {
        guard !scanning else {
            again = root
            return
        }
        scanning = true
        Task.detached(priority: .utility) {
            let found = NoteStore(root: root).names()
            let days = Dictations.days(notes: root.deletingLastPathComponent())
            await MainActor.run {
                if found != self.names { self.names = found }
                if days != self.dictationDays { self.dictationDays = days }
                let today = NoteWriter.dayString(Date())
                if today != self.today { self.today = today }
                self.scanning = false
                if let next = self.again {
                    self.again = nil
                    self.refresh(root: next)
                }
            }
        }
    }
}

/// One day of the Dictations list, newest first.
struct DictationDay: Hashable, Sendable {
    var day: String
    var entries: [Dictations.Entry]

    /// Every day's (a small file each), newest first.
    static func load(notes: URL) -> [DictationDay] {
        Dictations.days(notes: notes).map { DictationDay(day: $0, entries: Dictations.entries(day: $0, notes: notes)) }
    }
}
