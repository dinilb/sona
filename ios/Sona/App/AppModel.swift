import AVFoundation
import Foundation
import NotesKit
import Observation
import SonaEngine
import SwiftUI

/// What the screens show, in their terms. Everything the views need goes through here, so they never touch the
/// recorder, the processor or the files directly.
@MainActor
@Observable
final class AppModel {
    static let shared = AppModel()

    @ObservationIgnored let recorder: PhoneRecorder
    @ObservationIgnored let notes = NotesService.shared

    // MARK: navigation and onboarding

    /// The screens pushed on Home.
    var path: [Route] = []
    /// What Home's search has in it.
    var searchQuery = ""
    /// A place tapped on a note: Home lists only the notes made there (started or stopped there, the exact name), as a
    /// filter of its own beside the search, until it's cleared.
    var placeFilter: String?
    /// Onboarding has run (`V1Settings.onboardingDone`): Home shows instead.
    private(set) var onboardingDone: Bool
    /// The step onboarding opens on (`-debugOnboardingStep` in DEBUG builds; otherwise the welcome).
    @ObservationIgnored private(set) var onboardingStart = OnboardingStep.welcome

    // MARK: recording

    var isRecording: Bool { recorder.isRecording }
    var recordingStartedAt: Date? { recorder.startedAt }
    /// Set while a call or Siri has the mic: the panel says paused and its time stands still.
    var pausedAt: Date? { recorder.pausedAt }
    var wave: WaveScroll { recorder.wave }
    var recordingError: String? { actionError ?? recorder.lastError }
    /// A start that failed (no mic permission, say), shown under the button.
    private var actionError: String?
    /// The mic is turned off for Sona: the error comes with a button to Settings.
    private(set) var micDenied = false
    /// This launch found that the last recording was cut short: the app was closed or crashed while it recorded.
    /// Its audio is safe in the spool and becomes a note; a banner says so until the next recording.
    private(set) var cutShortAt: Date?
    @ObservationIgnored private let launchedAt = Date()

    /// Something that went wrong with an action (a delete, a folder), for an alert.
    var problem: String?
    /// The folder picker is open (a banner asks for the notes folder again).
    var choosingFolder = false

    private init() {
        #if DEBUG
        Self.applyDebugArguments()
        #endif
        // Before the recorder exists: making it clears the widgets' "recording since", which after a crash or a kill
        // mid-recording is the only sign of it.
        let cutShort = SharedStatus.load().recordingSince
        recorder = PhoneRecorder.shared
        onboardingDone = V1Settings.onboardingDone
        cutShortAt = cutShort
        #if DEBUG
        if let step = Self.debugOnboardingStep {
            onboardingDone = false
            onboardingStart = step
        }
        // `-debugSearch <words>` and `-debugPlace <name>`: Home opens searching, or on one place's notes (screenshots).
        searchQuery = Self.debugArgument("-debugSearch") ?? ""
        placeFilter = Self.debugArgument("-debugPlace")
        #endif
        // A recording the recorder just closed goes straight to the transcriber.
        recorder.onFinished = { [weak self] id in
            self?.notes.enqueue(id)
        }
    }

    /// At launch, foreground or not (an intent or the watch can launch the app in the background).
    func launch() {
        // First, so what the launch logs reaches the Mac's copy of this iPhone's log too.
        DiagnosticsLog.start()
        // A launch by the Record control, Siri or the watch has no screen: no waveform to feed until one appears.
        let onScreen = UIApplication.shared.applicationState != .background
        PhoneRecorder.levelsWanted.withLock { $0 = onScreen }
        WatchReceiver.shared.activate()
        notes.start()
        #if DEBUG
        RecordingDebug.runIfRequested()
        ProcessingDebug.runIfRequested()
        WatchDebug.runIfRequested()
        #endif
    }

    // MARK: recording actions

    func toggleRecording() async {
        if recorder.isRecording { await stopRecording() } else { await startRecording() }
    }

    func startRecording() async {
        actionError = nil
        micDenied = false
        cutShortAt = nil
        do {
            try await recorder.start()
        } catch {
            actionError = (error as? LocalizedError)?.errorDescription ?? "Couldn't start recording."
            if case RecordingError.micDenied = error { micDenied = true }
        }
    }

    /// Stop in the app (the button, or a widget's link that opened it): the note can carry on off screen if he
    /// leaves before it's written (`NotesService.finishOffScreen`).
    func stopRecording() async {
        actionError = nil
        micDenied = false
        await recorder.stop()
        notes.finishOffScreen()
    }

    /// A link a widget opened (see `linkAction`).
    func handle(_ url: URL) {
        let action = Self.linkAction(
            DeepLink.trusted(url: url), onboardingDone: onboardingDone, isRecording: isRecording, cutShortAt: cutShortAt,
            launchedAt: launchedAt, now: Date())
        switch action {
        case .start: Task { await startRecording() }
        case .stop: Task { await stopRecording() }
        case .nothing: break
        }
    }

    enum LinkAction: Equatable { case start, stop, nothing }

    /// How long after a launch that found a cut-short recording a record link is taken as the widget's stale "still
    /// recording" being tapped.
    static let cutShortGrace: TimeInterval = 10

    /// What a link does. Only one with this device's key does anything (any app or web page can open
    /// `sona://record`, but only our own widgets know the key). A record link only starts a recording when none is
    /// running, and never stops one; a stop link only stops one. Right after a launch that found the last recording
    /// cut short (the app was closed or crashed while it recorded), a record link comes from a widget that still showed
    /// that recording: it only opens the app, which says what happened, rather than starting a second recording.
    /// Before onboarding is done a record link only opens the app too: the welcome screen has no Stop, and the mic,
    /// where notes go and the model download haven't been asked about yet.
    static func linkAction(
        _ link: DeepLink?, onboardingDone: Bool, isRecording: Bool, cutShortAt: Date?, launchedAt: Date, now: Date
    ) -> LinkAction {
        switch link {
        case .record:
            if isRecording || !onboardingDone { return .nothing }
            if cutShortAt != nil, now.timeIntervalSince(launchedAt) < cutShortGrace { return .nothing }
            return .start
        case .stop:
            return isRecording ? .stop : .nothing
        case nil:
            return .nothing
        }
    }

    enum OutsideStart: Equatable { case record, openApp, stay, refuse }

    /// What a start from outside the app does (the Record control, Siri, the Action button). Before onboarding is done
    /// it never records, for the same reasons as a record link: off screen it opens Sona instead (at onboarding), on
    /// screen (Control Center over onboarding) it does nothing, and where iOS can't bring the app forward it says why.
    static func outsideStart(onboardingDone: Bool, offScreen: Bool, canOpenApp: Bool) -> OutsideStart {
        if onboardingDone { return .record }
        if !offScreen { return .stay }
        return canOpenApp ? .openApp : .refuse
    }

    // MARK: lifecycle

    /// Re-reads the notes (pull to refresh, coming back to the app).
    func refresh() async {
        await notes.refresh()
    }

    /// Back from the background: the notes may have changed. Only then: Control Center and alerts flip the app between
    /// inactive and active, and each list read parses every note. Off screen, the waveform isn't fed.
    func phaseChanged(from before: ScenePhase, to now: ScenePhase) {
        PhoneRecorder.levelsWanted.withLock { $0 = now == .active }
        // Coming back goes background -> inactive -> active, so remember the background rather than compare phases.
        if now == .background {
            wasInBackground = true
            // The Mac's copy of the log gets what happened on screen before iOS may suspend the app.
            DiagnosticsLog.copyGoingOffScreen()
        }
        if now == .active, wasInBackground {
            wasInBackground = false
            Task { await notes.refresh() }
        }
    }
    @ObservationIgnored private var wasInBackground = false

    // MARK: what the lists show

    /// Every row: the recordings that aren't notes yet, then the notes. Reads the spool on disk, so read it once per
    /// render.
    var rows: [NoteRow] {
        // The spool is files, not observed: read what changes with it every time, so the list redraws when a
        // recording stops or starts transcribing even if nothing was waiting when it last drew (a read made only
        // inside the loop below isn't tracked while the loop is empty).
        _ = (recorder.isRecording, notes.pending, notes.transcribingID, notes.failedIDs, notes.failed)
        let open = notes.spool.openID
        let modelReady = notes.modelState == .ready
        let recordings = notes.spool.pending(readOnly: true).filter { $0.id != open }.map { entry in
            let seconds = WavFile.duration(of: notes.spool.wav(entry.id))
            return NoteRow.recording(
                id: entry.id, startedAt: entry.startedAt, seconds: seconds, length: Lines.durationText(seconds),
                isWatch: Self.isWatch(entry.source), state: recordingState(entry.id), modelReady: modelReady)
        }
        return recordings + notes.notes.map(NoteRow.init(summary:))
    }

    /// Home's one list: recordings that aren't notes yet on top, then the notes, newest first.
    var homeRows: [NoteRow] { HomeOrder.rows(rows) }

    /// A recording's state by its id: the one being transcribed now, one that failed this launch, or waiting.
    private func recordingState(_ spoolID: String) -> NoteRow.State {
        if spoolID == notes.transcribingID { return .transcribing }
        if notes.failedIDs.contains(spoolID) { return .failed }
        return .waiting
    }

    nonisolated static func isWatch(_ source: String?) -> Bool { source?.lowercased().contains("watch") == true }

    /// The speech model's progress while it isn't ready (Home and onboarding); nil once it is.
    var modelProgress: ModelProgress? {
        ModelProgress(notes.modelState, allowed: V1Settings.modelDownloadAllowed)
    }

    var banners: [Banner] {
        var out: [Banner] = []
        if let cutShortAt {
            out.append(Banner(
                id: "cut-short",
                text: "Sona was closed while it was recording (from \(Format.time(cutShortAt))). What it recorded up to then is saved and turns into a note.",
                action: .dismissCutShort))
        }
        // The notes folder chosen can't be used now: notes wait on this iPhone (they move once it's back).
        if let location = notes.location {
            switch notes.notesChoice {
            case .icloud where location.kind != .iCloudContainer:
                out.append(Banner(
                    id: "icloud-off",
                    text: "iCloud Drive is off for Sona, so new notes wait on this iPhone. Turn on iCloud Drive in Settings and they move there.",
                    isProblem: true))
            case .folder where location.kind != .picked:
                out.append(Banner(
                    id: "folder-gone",
                    text: "Sona can't open the folder you picked, so new notes wait on this iPhone. Choose it again, or pick another place in Settings.",
                    isProblem: true, action: .chooseFolder))
            default:
                break
            }
        }
        if notes.failed > 0 {
            out.append(Banner(
                id: "failed", text: "\(notes.failed) recording\(notes.failed == 1 ? "" : "s") couldn't be transcribed. The audio is kept.",
                isProblem: true, action: .retryFailed))
        }
        return out
    }

    func perform(_ action: BannerAction) {
        switch action {
        case .chooseFolder: choosingFolder = true
        case .retryFailed: notes.retryFailed()
        case .dismissCutShort: cutShortAt = nil
        }
    }

    // MARK: notes

    /// Every note made at `place`: Home, filtered to that place exactly, with the search cleared.
    func showNotes(at place: String) {
        placeFilter = place
        searchQuery = ""
        path = []
    }

    func summary(_ id: String) -> NoteSummary? { notes.notes.first { $0.id == id } }

    func row(_ id: String) -> NoteRow? { summary(id).map(NoteRow.init(summary:)) }

    /// The whole note for its screen. One iCloud took off this iPhone to save room is downloaded first.
    func detail(_ id: String) async -> NoteDetail? {
        let note: ConversationNote?
        if let summary = summary(id) { note = await notes.open(summary) } else { note = notes.note(id) }
        guard let note else { return nil }
        return NoteDetail(note: note, audioURL: notes.audioURL(for: note))
    }

    /// A note's audio that iCloud took off this iPhone, once it's back (`detail` started its download): nil if the note
    /// has none there, or it doesn't come within `seconds` (offline). Stops waiting when the caller's task is cancelled.
    func downloadedAudio(_ id: String, waitingUpTo seconds: Double = 120) async -> URL? {
        guard let summary = summary(id), summary.hasAudio else { return nil }
        let m4a = summary.url.deletingPathExtension().appendingPathExtension("m4a")
        guard NotesService.isEvicted(m4a), await NotesService.fetchFromICloud(m4a, waitingUpTo: seconds) else {
            return nil
        }
        return AudioCompressor.keptAudio(of: summary.url)
    }

    /// Deletes a recording that isn't a note yet (waiting or failed), audio and all.
    func deleteRecording(_ row: NoteRow) {
        guard let id = row.spoolID else { return }
        if !notes.deleteRecording(id) { problem = "That recording is being transcribed right now. Try again when it's done." }
    }

    var audioPolicy: AudioPolicy { notes.audioPolicy }

    /// Keep audio is offered in 30-day mode, on notes that have audio.
    func offersKeepAudio(_ row: NoteRow) -> Bool {
        row.state == .note && row.hasAudio && notes.audioPolicy == .thirtyDays
    }

    /// Whether turning Keep audio off on `row` deletes its audio at once (in 30-day mode, a note that started over 30
    /// days ago): the swipe and the toggle confirm first then, like the stricter audio setting in Settings.
    func keepAudioOffDeletesAudio(_ row: NoteRow) -> Bool {
        guard row.keepAudio, row.hasAudio else { return false }
        // The note's own start, not the row's: a start that can't be read keeps its audio, as in AudioRetention.
        return Self.deletesAudioWithoutKeep(startedAt: summary(row.id)?.startedAt, policy: audioPolicy)
    }

    /// AudioRetention's rule for a note without Keep audio: true when `policy` doesn't keep its audio at `now`.
    nonisolated static func deletesAudioWithoutKeep(startedAt: Date?, policy: AudioPolicy, now: Date = Date()) -> Bool {
        !AudioRetention.keeps(startedAt: startedAt, keepAudio: false, policy: policy, now: now)
    }

    static let keepAudioOffTitle = "Delete this note's audio now?"
    static let keepAudioOffMessage =
        "It's over 30 days old, so its audio is deleted now, from this iPhone and from iCloud if that's where it is. Its text stays. This can't be undone."

    func setKeepAudio(_ keep: Bool, for row: NoteRow) async {
        guard let note = summary(row.id) else { return }
        do {
            try await notes.setKeepAudio(keep, for: note)
            await notes.refresh()  // so the row and the toggle show what's saved
        } catch {
            problem = "Couldn't change Keep audio on that note. Try again in a moment."
            Log.note("couldn't set keep audio: \(Log.describe(error))")
        }
    }

    /// Deletes a note (its text and audio). False if it couldn't (the alert says so).
    @discardableResult
    func delete(_ row: NoteRow) async -> Bool {
        guard let note = summary(row.id) else { return false }
        do {
            try await notes.delete(note)
            await notes.refresh()
            return true
        } catch {
            problem = "Couldn't delete that note. Try again in a moment."
            Log.note("couldn't delete a note: \(Log.describe(error))")
            return false
        }
    }

    static let deleteMessage =
        "Its text and audio are deleted from this iPhone, and from iCloud if that's where it is. This can't be undone. A copy Sona for Mac already took stays on the Mac."

    /// Tries a recording that failed this launch again.
    func retry(_ row: NoteRow) {
        guard let id = row.spoolID else { return }
        notes.retry(id)
    }

    // MARK: settings

    var notesChoice: NotesChoice? { notes.notesChoice }

    /// Where notes go now, in words: "iCloud Drive", "On this iPhone" or the picked folder's name.
    var notesPlaceName: String? { notes.location?.displayName }

    /// Moves notes to `choice` (`folder` only for `.folder`). Nil when it worked, else what went wrong. A folder
    /// picked before v1 (an existing install) is kept as it is when `.folder` is chosen with no new folder.
    func setNotesChoice(_ choice: NotesChoice, folder: URL?) async -> String? {
        if choice == .folder, folder == nil, !Self.hasPickedFolder { return "Choose a folder first." }
        do {
            try await notes.setNotesChoice(choice, folder: folder)
            return nil
        } catch {
            Log.note("couldn't change where notes go: \(Log.describe(error))")
            return choice == .folder
                ? "Sona couldn't use that folder. Pick another one, or choose iCloud or On this iPhone."
                : "Sona couldn't change where notes go. Try again in a moment."
        }
    }

    /// How many audio files a policy would delete now (for the confirm before a stricter one).
    func audioFilesRemoved(by policy: AudioPolicy) async -> Int {
        await notes.audioFilesRemoved(by: policy)
    }

    func setAudioPolicy(_ policy: AudioPolicy) async {
        await notes.setAudioPolicy(policy)
    }

    // MARK: onboarding

    /// The welcome screen's Continue: it said what the speech model is and how big, so it downloads from now on.
    func allowModelDownload() {
        V1Settings.modelDownloadAllowed = true
        notes.ensureModels()
    }

    func finishOnboarding() {
        V1Settings.onboardingDone = true
        onboardingDone = true
    }

    /// Where onboarding's notes step starts.
    var defaultNotesChoice: NotesChoice {
        OnboardingDefaults.notesChoice(
            saved: notes.notesChoice, hasPickedFolder: Self.hasPickedFolder,
            iCloudSignedIn: FileManager.default.ubiquityIdentityToken != nil)
    }

    /// Where onboarding's audio choice starts. Read again when the notes are listed: an install with notes keeps them.
    var defaultAudioPolicy: AudioPolicy {
        OnboardingDefaults.audioPolicy(
            saved: V1Settings.audioPolicySaved ? notes.audioPolicy : nil,
            existingInstall: Self.hasPickedFolder || !notes.notes.isEmpty)
    }

    var iCloudSignedIn: Bool { FileManager.default.ubiquityIdentityToken != nil }

    /// A folder was picked before (an install from before v1, or Other folder).
    static var hasPickedFolder: Bool { FileManager.default.fileExists(atPath: PickedFolder.bookmarkFile.path) }

    // MARK: debug

    #if DEBUG
    /// `-debugSkipOnboarding`: onboarding counts as done with its defaults (notes on this iPhone, or in the
    /// `-debugNotesFolder` folder; audio kept 30 days; the speech model downloads), so simulator runs and screenshots
    /// reach Home. Before anything reads the settings.
    private static func applyDebugArguments() {
        let args = ProcessInfo.processInfo.arguments
        guard args.contains("-debugSkipOnboarding") else { return }
        V1Settings.notesChoice = args.contains("-debugNotesFolder") ? .folder : .iphone
        V1Settings.audioPolicy = .thirtyDays
        // `-debugNoModelDownload`: screenshots of the lists and notes without the 480 MB download starting.
        V1Settings.modelDownloadAllowed = !args.contains("-debugNoModelDownload")
        V1Settings.onboardingDone = true
    }

    /// The value after a launch argument (`-debugSearch lunch`), if it's there.
    static func debugArgument(_ name: String) -> String? {
        let args = ProcessInfo.processInfo.arguments
        guard let i = args.firstIndex(of: name), i + 1 < args.count else { return nil }
        return args[i + 1]
    }

    /// `-debugOnboardingStep N`: onboarding opens at screen N (1 welcome, 2 your notes, 3 what Sona asks for), for
    /// screenshots. It doesn't change what's saved.
    static var debugOnboardingStep: OnboardingStep? {
        let args = ProcessInfo.processInfo.arguments
        guard let i = args.firstIndex(of: "-debugOnboardingStep"), i + 1 < args.count, let n = Int(args[i + 1]) else {
            return nil
        }
        return OnboardingStep(rawValue: min(max(n, OnboardingStep.welcome.rawValue), OnboardingStep.allCases.count))
    }
    #endif
}

// MARK: - What the views show

extension NoteRow {
    init(summary note: NoteSummary) {
        let start = note.startedAt ?? DayList.date(ofNoteID: note.id) ?? .distantPast
        // The header's end time when it has one; the length rounds to the minute past an hour.
        let end = note.endedAt ?? note.startedAt.flatMap { start in Format.seconds(fromLength: note.duration).map { start.addingTimeInterval($0) } }
        self.init(
            id: note.id, state: .note, title: note.displayTitle, startedAt: start, endedAt: end, length: note.duration,
            place: note.place, placeEnd: note.placeEnd, isWatch: AppModel.isWatch(note.source), keepAudio: note.keepAudio,
            hasAudio: note.hasAudio, isSynced: note.isSynced)
        keptOnIPhone = note.keptOnIPhone
    }
}

/// Where onboarding's choices start.
nonisolated enum OnboardingDefaults {
    /// A choice already made wins; then a folder picked before v1 (an existing install keeps it); then iCloud when
    /// the phone is signed in to it; else this iPhone.
    static func notesChoice(saved: NotesChoice?, hasPickedFolder: Bool, iCloudSignedIn: Bool) -> NotesChoice {
        if let saved { return saved }
        if hasPickedFolder { return .folder }
        return iCloudSignedIn ? .icloud : .iphone
    }

    /// A setting already saved wins; then Keep forever for an install that already has notes (from before v1, when
    /// audio was always kept), so going straight on keeps what's there; else 30 days.
    static func audioPolicy(saved: AudioPolicy?, existingInstall: Bool) -> AudioPolicy {
        if let saved { return saved }
        return existingInstall ? .forever : .thirtyDays
    }
}

/// The speech model's progress line while it isn't ready: on Home and on every onboarding step after the welcome.
/// It downloads by itself (no button), so this only says how far it's got.
struct ModelProgress: Equatable {
    var text: String
    /// The bar, 0...1; nil when there's no bar (the download stopped and waits to try again).
    var fraction: Double?
    var stopped = false

    /// Under the bar on Home.
    static let keepOpen = "Keep Sona open, it takes a couple of minutes on Wi-Fi. You can record now: it turns into text when it's done."

    /// Nil when the model is ready, or before the welcome screen allowed the download.
    init?(_ state: NotesService.ModelState, allowed: Bool) {
        switch state {
        case .ready:
            return nil
        case .missing:
            guard allowed else { return nil }
            // About to start, or picking up again after the app was off screen.
            text = "Downloading the local speech model, please wait..."
            fraction = 0
        case .downloading(let value, let phrase):
            let value = min(max(value, 0), 1)
            text = phrase.hasPrefix("Preparing")
                ? "Getting the speech model ready, please wait..."
                : "Downloading the local speech model, please wait... \(Int((value * 100).rounded(.down)))%"
            fraction = value
        case .failed:
            text = "The speech model download stopped. Sona tries again by itself in a moment, from where it got to."
            fraction = nil
            stopped = true
        }
    }
}

struct Banner: Identifiable, Equatable {
    var id: String
    var text: String
    var isProblem = false
    var action: BannerAction?
}

enum BannerAction: Equatable {
    case chooseFolder
    case retryFailed
    case dismissCutShort

    var title: String {
        switch self {
        case .chooseFolder: "Choose folder"
        case .retryFailed: "Try again"
        case .dismissCutShort: "OK"
        }
    }
}

/// One note, read in full for its screen.
struct NoteDetail {
    var title: String
    var startedAt: Date?
    var endedAt: Date?
    var length: String
    var place: String?
    var placeEnd: String?
    var speakers: [String]
    var source: String?
    var lines: [NoteLine]
    var audioURL: URL?
    var markdown: String

    init(note: ConversationNote, audioURL: URL?) {
        title = note.displayTitle
        startedAt = note.startedAt
        endedAt = note.endedAt
        length = note.duration
        place = note.place
        placeEnd = note.placeEnd
        speakers = note.speakers
        source = note.source
        lines = note.lines
        self.audioURL = audioURL
        let raw = (try? String(contentsOf: note.url, encoding: .utf8)) ?? note.displayTitle
        markdown = Self.shareable(raw)
    }

    /// What Share sends: the note without its exact coordinates (`geo`, `geo_end`), which the screen never shows.
    /// The place names stay.
    nonisolated static func shareable(_ markdown: String) -> String {
        NoteFrontMatter.update(markdown, set: ["geo": nil, "geo_end": nil])
    }

    /// "Speaker 1 · Speaker 2 · from watch": who's in it, and "from watch" for a note the watch recorded.
    var about: String? {
        let parts = speakers + [Format.origin(source)].compactMap { $0 }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    /// "Today, 6 Nov · 7:05am – 11am · 18m 28s".
    var when: String {
        guard let startedAt else { return length }
        return [Format.dayLabel(startedAt), Format.timeRange(startedAt, endedAt), length].joined(separator: " · ")
    }
}
