import BackgroundTasks
import Foundation
import NotesKit
import Observation
import SonaEngine
import Network
import UIKit
import os

/// Turns recordings into notes on the iPhone with the Mac's own pipeline: a recording is a closed `SpoolEntry` plus
/// its 16 kHz WAV in `Services.spool`, and SonaEngine's `Processor` writes it as the same .md + .json as the Mac,
/// keeping the audio, which is then made an .m4a beside the note.
///
/// It feeds the Processor one recording at a time, so it decides when the next one may start (`gate`): with the
/// models on disk, and while the app is in the foreground, the charging task runs, or the off-screen task asked for
/// at a stop runs (`ContinuedProcessing`). Otherwise, off screen, a recording that comes in (a stop from the Lock
/// Screen or Siri, the watch) is written on the ~30 s of background time iOS gives, if it's 30 s or less and fits; a
/// longer one waits for one of those.
@MainActor @Observable
final class NotesService {
    static let shared = NotesService(spool: Services.spool)
    /// Parakeet TDT v2 (English), like the Mac's notes.
    static let model = "v2"

    enum ModelState: Equatable, Sendable {
        case missing
        case downloading(fraction: Double, phrase: String)
        case ready
        case failed(String)
        /// Not enough free space to download the rest and still record: this many bytes short. It waits for the next
        /// launch or foreground instead of trying every 2 minutes (each try's partial files took more of the space).
        case noSpace(bytes: Int64)
    }

    /// Recordings waiting to become notes, the one being transcribed included.
    private(set) var pending = 0
    /// A note is being transcribed.
    private(set) var busy = false
    /// Why the last note failed (never a path or a title); nil after a note is written.
    private(set) var lastError: String?
    /// Recordings that failed 3 times: in Spool/failed, their audio kept.
    private(set) var failed = 0
    /// Newest first: the notes where notes go and the ones still waiting on this iPhone to move there.
    private(set) var notes: [NoteSummary] = []
    /// Where notes go now (the app's iCloud container, this iPhone's Documents/Notes, the picked folder, or staging
    /// while they wait); nil until `start` has looked.
    private(set) var location: NotesLocation?
    private(set) var modelState: ModelState = .missing
    /// Where notes go, as chosen in onboarding or Settings; nil until then. An older install with a picked folder
    /// counts as `.folder`.
    private(set) var notesChoice: NotesChoice? = V1Settings.notesChoice
    /// How long a note's audio stays (`AudioRetention`).
    private(set) var audioPolicy: AudioPolicy = V1Settings.audioPolicy
    /// The spool id being transcribed now, for its row.
    private(set) var transcribingID: String?
    /// Spool ids that failed this launch and wait in the spool (tried again on the next launch, or now with `retry`).
    private(set) var failedIDs: Set<String> = []

    /// Why notes wait on this iPhone instead of going where they were chosen to go (iCloud off, the picked folder
    /// gone), for a banner; nil when they go there.
    var notesWaiting: NotesLocation.Waiting? { location?.waiting }

    @ObservationIgnored let spool: Spool
    @ObservationIgnored private var processor: Processor?
    /// Spool ids to transcribe, oldest first.
    @ObservationIgnored private(set) var queue: [String] = []
    @ObservationIgnored private var started = false
    /// The folder is known and the Processor made.
    @ObservationIgnored private var ready = false
    @ObservationIgnored private var feeding = false
    /// Something was queued while the feed was finishing: it runs once more.
    @ObservationIgnored private var pumpAgain = false
    @ObservationIgnored private var locationCheckNeeded = false
    /// Something is converting, titling, moving, deleting or editing notes in staging (`claimStaging`): the next one
    /// waits, so a note is never half moved and half deleted.
    @ObservationIgnored private var stagingBusy = false
    /// Where each note moved out of staging this launch went, by its staging `.md` path (`publishLocalNotes`). A row
    /// lists a new note from staging while the feed still titles it, so a delete or Keep audio from that row can
    /// wait for staging while the note moves: they find it here (it may have moved as "... 2").
    @ObservationIgnored private var movedNotes: [String: URL] = [:]
    @ObservationIgnored private var appInBackground = false
    /// The note being transcribed was in the background at some point (a failure then isn't its fault).
    @ObservationIgnored private var noteSawBackground = false
    /// A background failure or running out of background time: the background tasks take nothing more until the
    /// foreground (a new recording's background time still takes a short one, `gate`).
    @ObservationIgnored private var stopInBackground = false
    /// Background time held while Sona is off screen: for the note under way when he left, and for a recording that
    /// came in off screen (`holdBackgroundTime`). Ends when the feed stops, or when iOS says time's up.
    @ObservationIgnored private var finishHold: BackgroundTime?
    /// Recordings that failed or ran out of time in the background since Sona was last on screen: background time
    /// isn't spent on them again (they wait for the foreground or a background task).
    @ObservationIgnored private var backgroundMisses: Set<String> = []
    @ObservationIgnored private var processingTask: BackgroundProcessing.Handle?
    /// The off-screen task asked for when he tapped Stop (`ContinuedProcessing`), while it runs.
    @ObservationIgnored private var continuedTask: BackgroundProcessing.Handle?
    /// Moves that task's bar every second while it runs: iOS ends one whose bar sits still.
    @ObservationIgnored private var continuedTicker: Task<Void, Never>?
    /// Notes written, and notes it set out to write, since that task started: its bar.
    @ObservationIgnored private var continuedDone = 0
    @ObservationIgnored private var continuedTotal = 0
    /// The note being transcribed now: when it started, how long its audio is, and whether it's on the CPU (the bar's
    /// guess at how far it's got).
    @ObservationIgnored private var currentSince: Date?
    @ObservationIgnored private var currentSeconds: Double = 0
    @ObservationIgnored private var currentOnCPU = false
    /// Where the off-screen task's bar was within the note when this try of it began (`ContinuedProgress.next`).
    @ObservationIgnored private var currentBase: Int64 = 0
    /// The app is on screen, for the expiration handlers, which run off the main actor: a note the app carries on with
    /// on screen isn't cut short, so it keeps its attempt.
    nonisolated static let onScreen = OSAllocatedUnfairLock(initialState: false)
    @ObservationIgnored private var observers: [NSObjectProtocol] = []
    /// The recording being transcribed and its attempts before this one, to give the attempt back if it's cut short.
    /// Set with `setCurrent`.
    @ObservationIgnored private var current: (id: String, attempts: Int)?
    /// `current` for the charging task's expiration handler, which runs on a background queue and must give the
    /// attempt back before it completes the task (iOS may suspend the app right after).
    nonisolated static let inFlight = OSAllocatedUnfairLock<(id: String, attempts: Int, spool: Spool)?>(initialState: nil)
    /// The foreground pass for places and titles, while it runs.
    @ObservationIgnored private var enriching: Task<Void, Never>?
    /// The model download now, one at a time (`ensureModels`).
    @ObservationIgnored private var downloadTask: Task<Void, Never>?
    /// The next try after a failed download.
    @ObservationIgnored private var retryTask: Task<Void, Never>?
    @ObservationIgnored private var downloadFailures = 0
    /// The furthest the bar got in this download, so it never goes backwards. Each download starts it from the bytes
    /// on disk, so one picked up again doesn't start from 0.
    @ObservationIgnored private var bestFraction = 0.0
    /// The ~30 s of background time a download gets when the app leaves the screen.
    @ObservationIgnored private var downloadHold: UIBackgroundTaskIdentifier = .invalid
    @ObservationIgnored private var networkMonitor: NWPathMonitor?
    @ObservationIgnored private var networkUp = true

    init(spool: Spool) {
        self.spool = spool
    }

    // MARK: API

    /// At launch: keeps the recordings and notes on this iPhone out of backups, finds the notes folder
    /// (`NotesLocation`), keeps the models offline, and queues what's left in the spool. Returns at once; the rest
    /// runs in a task. Calling it again does nothing.
    func start() {
        guard !started else { return }
        started = true
        Self.protectPrivateFolders(spool: spool.dir)
        // An install from before v1 with a picked folder keeps it (nothing moves); onboarding shows it chosen.
        if V1Settings.notesChoice == nil, PickedFolder.isRemembered { V1Settings.notesChoice = .folder }
        notesChoice = V1Settings.notesChoice
        audioPolicy = V1Settings.audioPolicy
        appInBackground = UIApplication.shared.applicationState == .background
        let onScreen = !appInBackground
        Self.onScreen.withLock { $0 = onScreen }
        Models.goOffline()
        modelState = Models.isReady(model: Self.model) ? .ready : .missing
        observe()
        if modelState != .ready { networkMonitor = Self.watchNetwork() }
        Task { await setUp() }
    }

    /// He tapped Stop in the app: if he leaves it before the notes waiting are written, they carry on off screen, with
    /// a bar on the Lock Screen (`ContinuedProcessing`). Only with the app on screen (iOS runs none asked for from the
    /// background) and the models ready; while one runs, it takes everything that waits, so none is asked for twice.
    func finishOffScreen() {
        // What the feed will take: not the failed ones `pending` also counts.
        let recordings = queue.count + (busy ? 1 : 0)
        guard modelState == .ready, continuedTask == nil, recordings > 0,
            UIApplication.shared.applicationState == .active
        else { return }
        Task { _ = await ContinuedProcessing.request(recordings: recordings) }
    }

    /// A recording the recorder (or the watch) just closed. Off screen (a stop from the Lock Screen or Siri, a watch
    /// recording), it's written now on the background time iOS gives, if it's short enough, instead of waiting for
    /// Sona to be opened.
    func enqueue(_ spoolID: String) {
        if !queue.contains(spoolID), current?.id != spoolID { queue.append(spoolID) }
        failedIDs.remove(spoolID)
        if let entry = spool.load(spoolID) {
            let from = AppModel.isWatch(entry.source) ? "the watch" : "this iPhone"
            Log.note("recording \(Log.ref(entry.startedAt)) from \(from) queued, Sona \(appInBackground ? "off" : "on") screen")
        }
        if appInBackground { holdBackgroundTime() }
        publish()
        pump()
    }

    /// A recording that failed, now: one that failed this launch (`failedIDs`), or one in Spool/failed after its 3
    /// tries (back with its attempts at 0). For a failed row's "Try again".
    func retry(_ spoolID: String) {
        if spool.load(spoolID) == nil, Self.isFailed(spoolID, in: spool) {
            Self.moveBack(spoolID, in: spool)
            if var entry = spool.load(spoolID), entry.attempts > 0 {
                entry.attempts = 0
                spool.save(entry, durable: true)
            }
        }
        guard spool.load(spoolID) != nil else { return }
        enqueue(spoolID)
    }

    /// Deletes a recording that isn't a note yet (waiting, or failed): its audio and entry, in the spool or in
    /// Spool/failed. Not the one being recorded or transcribed now (false).
    @discardableResult
    func deleteRecording(_ spoolID: String) -> Bool {
        guard spoolID != spool.openID, spoolID != current?.id else { return false }
        queue.removeAll { $0 == spoolID }
        failedIDs.remove(spoolID)
        spool.remove(spoolID)
        Spool(dir: spool.failedDir(), create: false).remove(spoolID)
        Log.note("a recording was deleted before it became a note")
        publish()
        return true
    }

    /// Deletes every recording in Spool/failed (the ones that failed 3 times, `failed`), audio and all: a Delete
    /// beside the failed banner's "Try again". Returns how many went.
    @discardableResult
    func deleteFailedRecordings() -> Int {
        let failedSpool = Spool(dir: spool.failedDir(), create: false)
        let entries = failedSpool.pending(readOnly: true)
        for entry in entries { failedSpool.remove(entry.id) }
        if !entries.isEmpty { Log.note("\(entries.count) failed recording(s) deleted") }
        publish()
        return entries.count
    }

    /// Reads the notes list again: where notes go, staging (notes waiting on this iPhone to move there), and, once
    /// notes go anywhere else, the notes kept "On this iPhone" before (nothing else shows that folder, not even Files).
    func refresh() async {
        guard let location else { return }
        let staging = NotesLocation.stagingFolder.appendingPathComponent("Conversations", isDirectory: true)
        let destination = location.kind == .local ? nil : location.conversations
        let kept = location.kind == .iphone
            ? nil : NotesLocation.iPhoneFolder.appendingPathComponent("Conversations", isDirectory: true)
        notes = await Task.detached { NoteSummary.list(destination: destination, staging: staging, kept: kept) }.value
        publish()
    }

    /// A listed note as it is on disk now (nil if this iPhone doesn't have it: use `open` for one iCloud evicted).
    /// An id that isn't listed matches only that very file, never another note whose name starts the same ("09-00
    /// Conversation 2" for a deleted "09-00 Conversation"), so a screen never shows, deletes or edits another note.
    func note(_ id: String) -> ConversationNote? {
        if let summary = notes.first(where: { $0.id == id }) { return Self.read(summary.url) }
        guard let root = location?.conversations, let url = Self.exactNote(id, in: root) else { return nil }
        return Self.read(url)
    }

    /// `<root>/<id>.md` if that very file is there; nil for anything else (no prefix or loose match, no path out).
    nonisolated static func exactNote(_ id: String, in root: URL) -> URL? {
        guard !id.isEmpty, !id.hasPrefix("/"), !id.contains("..") else { return nil }
        let url = root.appendingPathComponent(id + ".md")
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    /// The whole note, for its screen. One iCloud evicted from this iPhone is downloaded first (waiting up to
    /// `seconds`), and its audio starts downloading. Nil if it can't be read (deleted, or not here and offline).
    func open(_ note: NoteSummary, waitingUpTo seconds: Double = 30) async -> ConversationNote? {
        let url = note.url
        return await Task.detached { () async -> ConversationNote? in
            let m4a = url.deletingPathExtension().appendingPathExtension("m4a")
            if Self.isEvicted(m4a) { try? FileManager.default.startDownloadingUbiquitousItem(at: m4a) }
            guard await Self.fetchFromICloud(url, waitingUpTo: seconds) else { return nil }
            return Self.readCoordinated(url)
        }.value
    }

    /// The note's audio: its .m4a, or its .wav while that's not converted yet. Nil while it's only in iCloud.
    func audioURL(for note: ConversationNote) -> URL? {
        AudioCompressor.keptAudio(of: note.url)
    }

    /// Deletes a note and its own files (.json, audio) where it is, coordinated (iCloud deletes it everywhere), and
    /// the Mac's title for it (`TitlesFile`). A copy the Mac already imported stays on the Mac. A note still in
    /// staging waits for the feed to be done with it, then is deleted where it is by then. Throws if it isn't
    /// anywhere, so a delete that found nothing never looks like one that worked.
    func delete(_ note: NoteSummary) async throws {
        await claimStaging()
        defer { releaseStaging() }
        let listed = note.url, moved = movedNotes
        let staging = NotesLocation.stagingFolder.appendingPathComponent("Conversations", isDirectory: true)
        let folder = location.flatMap { $0.kind == .local ? nil : $0.conversations }
        try await Task.detached {
            let url = Self.whereNow(listed, moved: moved) ?? listed
            try Self.deleteNote(at: url, staging: staging, notesFolder: folder)
            // The Mac's title was made from the note's words, so it goes too. The note is gone either way.
            do { try TitlesFile.removeTitle(ofNote: url) } catch {
                Log.note("couldn't take a deleted note's title out of the titles file: \(Log.describe(error))")
            }
        }.value
        notes.removeAll { $0.id == note.id }
        Log.note("a note was deleted")
        publish()
    }

    /// Deletes the note at `url` (`NoteFiles.delete`). One still in staging whose move was cut short after its .json
    /// went (the .json moves first) left that .json, maybe its audio, in the notes folder with no .md beside them:
    /// nothing lists them and they hold its words, so they go too. With its .json still in staging none of it moved,
    /// and files there under its name are another note's (`NotesLocation.moveNote`): never touched. Blocking.
    nonisolated static func deleteNote(at url: URL, staging: URL, notesFolder: URL?) throws {
        func same(_ a: URL, _ b: URL) -> Bool {
            a.standardizedFileURL.resolvingSymlinksInPath().path == b.standardizedFileURL.resolvingSymlinksInPath().path
        }
        let dayDir = url.deletingLastPathComponent(), stem = url.deletingPathExtension().lastPathComponent
        let jsonHere = FileManager.default.fileExists(atPath: dayDir.appendingPathComponent(stem + ".json").path)
        try NoteFiles.delete(url)
        guard same(dayDir.deletingLastPathComponent(), staging), !jsonHere, let notesFolder else { return }
        let destDir = notesFolder.appendingPathComponent(dayDir.lastPathComponent, isDirectory: true)
        func there(_ ext: String) -> URL { destDir.appendingPathComponent("\(stem).\(ext)") }
        // Only a move of this note that got its .json there, and never a note that's there (its .md).
        guard !same(destDir, dayDir), NoteFiles.exists(there("json")), !NoteFiles.exists(there("md")) else { return }
        do {
            for ext in NotesLocation.noteExtensions where ext != "md" { try NotesLocation.deleteThere(there(ext)) }
            Log.note("a deleted note's files a cut-short move left in the notes folder went too")
        } catch {
            Log.note("couldn't delete what a cut-short move left of a deleted note: \(Log.describe(error))")
        }
    }

    /// Keep audio on or off for a note (`keep_audio: true` in its front matter): its audio stays whatever the setting.
    /// Turned off on a note the setting doesn't keep (over 30 days old), its audio goes now.
    func setKeepAudio(_ keep: Bool, for note: NoteSummary) async throws {
        await claimStaging()
        let listed = note.url, moved = movedNotes
        let value: String? = keep ? "true" : nil
        do {
            // Where it is now: a note listed from staging may have moved while this waited (see `delete`).
            try await Task.detached {
                try NoteFiles.updateFrontMatter(Self.whereNow(listed, moved: moved) ?? listed, set: ["keep_audio": value])
            }.value
        } catch {
            releaseStaging()
            throw error
        }
        if let i = notes.firstIndex(where: { $0.id == note.id }) { notes[i].keepAudio = keep }
        if !keep { await sweepAudio(refreshing: false) }
        releaseStaging()
        await refresh()
    }

    // MARK: where notes go, how long audio stays

    /// Where notes go from now on (onboarding, Settings). `folder`: the picked folder, only for `.folder` (nil keeps
    /// the one picked before). Leaving `.folder` forgets the picked folder. Notes already in the old place stay
    /// there; notes still waiting on this iPhone move to the new one, once the note being written (if any) is done.
    /// Throws if the folder can't be reached or remembered, or `.folder` comes with none.
    func setNotesChoice(_ choice: NotesChoice, folder: URL?) async throws {
        if choice == .folder {
            if let folder {
                try await Task.detached { try PickedFolder.save(folder) }.value
            } else if !PickedFolder.isRemembered {
                throw CocoaError(.fileNoSuchFile)
            }
        } else {
            PickedFolder.forget()
        }
        let old = V1Settings.notesChoice
        V1Settings.notesChoice = choice
        notesChoice = choice
        Log.note("notes go to: \(choice.rawValue)")
        // The log's copy is only kept while notes go to the app's iCloud folder (`DiagnosticsLog`).
        if old == .icloud, choice != .icloud { DiagnosticsLog.notesLeftICloud() }
        locationCheckNeeded = true
        pump()
    }

    /// How many notes' audio `policy` would delete now, for the confirm before a stricter setting.
    /// Counted where notes go now and where the saved choice says they go: right after a new choice (onboarding asks
    /// this a step later) the feed may not have switched yet, it does that between notes, and the sweep after it
    /// would delete audio the count missed (an install from before v1 with all its notes in iCloud).
    /// Notes iCloud took off this iPhone count too ("up to"): their audio goes once they download, with no confirm
    /// then, so the confirm asks whenever any may go.
    func audioFilesRemoved(by policy: AudioPolicy) async -> Int {
        await audioRemoval(by: policy).upTo
    }

    /// `audioFilesRemoved`, split: the notes whose audio goes now, and the ones not downloaded that may lose it.
    func audioRemoval(by policy: AudioPolicy) async -> AudioRetention.Removal {
        let current = audioFolders
        return await Task.detached {
            AudioRetention.removal(by: policy, in: Self.audioFolders(current, adding: NotesLocation.resolve()))
        }.value
    }

    /// `folders` and `target`'s notes, once: where the audio setting will apply once notes go to `target`.
    nonisolated static func audioFolders(_ folders: [URL], adding target: NotesLocation) -> [URL] {
        guard target.kind != .local else { return folders }
        let path = target.conversations.standardizedFileURL.path
        return folders.contains { $0.standardizedFileURL.path == path } ? folders : folders + [target.conversations]
    }

    /// Sets how long audio stays, and deletes now what the new setting doesn't keep. From now on "Delete once
    /// transcribed" keeps no audio at all (the Processor doesn't keep the WAV).
    func setAudioPolicy(_ policy: AudioPolicy) async {
        V1Settings.audioPolicy = policy
        audioPolicy = policy
        Log.note("audio setting: \(policy.rawValue)")
        await processor?.update(settings: processorSettings)
        await claimStaging()
        await sweepAudio(refreshing: false)
        releaseStaging()
        await refresh()
    }

    /// Downloads the speech model (about 480 MB, the app's one use of the network) if it isn't on disk, with no
    /// button. The first screen says what it is and how big, and going on allows it (`V1Settings.modelDownloadAllowed`,
    /// App Review 4.2.3(ii)); from then on it just runs. It's called at launch, on each foreground, when the network
    /// comes back and a little while after a failure, and does nothing while one runs or the app is off screen.
    /// While it runs the screen stays awake. Off screen it gets the ~30 s iOS gives, then stops (FluidAudio keeps the
    /// files it has and the part of the one it was on) and picks up from there when the app is back.
    func ensureModels() {
        guard V1Settings.modelDownloadAllowed, !appInBackground, downloadTask == nil else { return }
        switch modelState {
        case .ready, .downloading: return
        case .missing, .failed, .noSpace: break
        }
        retryTask?.cancel()
        retryTask = nil
        downloadTask = Task {
            await download()
            downloadTask = nil
            // Stopped for the background, and the app came back before it had wound down: carry on now.
            if !appInBackground, modelState == .missing { ensureModels() }
        }
    }

    /// Allows the download (what the first screen's Continue does), starts it if it isn't running, and waits for it.
    func downloadModels() async {
        V1Settings.modelDownloadAllowed = true
        ensureModels()
        await downloadTask?.value
    }

    private func download() async {
        let model = Self.model
        // Room for the rest of it and for recording (the 200 MB Record needs), or it doesn't start.
        if let short = await Self.spaceShort(model: model) {
            waitForSpace(short)
            return
        }
        // From what's on disk now, not the furthest the bar got: if FluidAudio deleted a model whose load failed, the
        // bar goes back with it instead of sitting near the end while it downloads again.
        bestFraction = await Task.detached { Models.downloadFractionOnDisk(model: model) }.value
        modelState = .downloading(fraction: bestFraction, phrase: "Downloading the speech model...")
        // Auto-Lock would suspend the app a minute in; the download only moves while Sona is on screen.
        UIApplication.shared.isIdleTimerDisabled = true
        defer { UIApplication.shared.isIdleTimerDisabled = false }
        let t0 = Date()
        do {
            try await Models.prepare(model: Self.model) { fraction, phrase in
                Task { @MainActor in NotesService.shared.downloadProgress(fraction, phrase) }
            }
            modelState = .ready
            downloadFailures = 0
            Log.note("speech model ready in \(Int(Date().timeIntervalSince(t0))) s")
            Self.excludeFromBackup(Paths.models)
            recover(onlyClosed: true)
            pump()
        } catch {
            if Task.isCancelled {
                // Stopped for the background (`pauseDownload`): not a failure, it carries on when the app is back.
                modelState = .missing
                Log.note("speech model download paused off screen")
            } else if let short = await Self.spaceShort(model: model) {
                // It ran out of room on the way (what it needs is a guess, and other apps write too): the reason is
                // the space, so it says how much, and trying again in 2 minutes would only fill the phone up more.
                Log.note("couldn't download the models: \(Log.describe(error))")
                waitForSpace(short)
                return
            } else {
                downloadFailures += 1
                modelState = .failed(Log.describe(error))
                Log.note("couldn't download the models (\(downloadFailures) in a row): \(Log.describe(error))")
                scheduleDownloadRetry()
            }
        }
        endDownloadHold()
    }

    /// Bytes short of the space the rest of the download and a recording need, or nil when there's room (or the free
    /// space can't be read).
    private static func spaceShort(model: String) async -> Int64? {
        await Task.detached {
            spaceShortfall(free: PhoneRecorder.freeBytes(at: Paths.support), left: Models.bytesLeftToDownload(model: model))
        }.value
    }

    /// How many bytes `free` is short of what's `left` to download plus the room to record afterwards
    /// (`PhoneRecorder.minFreeBytes`); nil when it's enough, or unknown (it tries then, as before).
    nonisolated static func spaceShortfall(free: Int64?, left: Int64) -> Int64? {
        guard let free else { return nil }
        let needed = left + PhoneRecorder.minFreeBytes
        return free < needed ? needed - free : nil
    }

    /// Stops until the next launch or foreground (`ensureModels`): no retry timer, and the network coming back doesn't
    /// try either.
    private func waitForSpace(_ short: Int64) {
        modelState = .noSpace(bytes: short)
        Log.note("speech model download waits for space: \((short + 999_999) / 1_000_000) MB short")
        endDownloadHold()
    }

    /// Tries again after a failure: 5 s, then 15, 45, and every 2 minutes after that, while the app is on screen
    /// (coming back to it, or the network coming back, tries at once).
    private func scheduleDownloadRetry() {
        retryTask?.cancel()
        let wait = min(5 * pow(3, Double(max(0, downloadFailures - 1))), 120)
        retryTask = Task {
            try? await Task.sleep(for: .seconds(wait))
            guard !Task.isCancelled else { return }
            retryTask = nil
            ensureModels()
        }
    }

    /// Off screen: stop the download, keeping what it has. Never let FluidAudio's Neural Engine prep run in the
    /// background: iOS 27 refuses it there, and a failed load makes FluidAudio delete the model and download it again.
    private func pauseDownload() {
        downloadTask?.cancel()
        endDownloadHold()
    }

    private func endDownloadHold() {
        guard downloadHold != .invalid else { return }
        UIApplication.shared.endBackgroundTask(downloadHold)
        downloadHold = .invalid
    }

    private func networkChanged(up: Bool) {
        let cameBack = up && !networkUp
        networkUp = up
        if cameBack, case .failed = modelState { ensureModels() }
    }

    /// Calls `networkChanged` on the main actor whenever the network comes or goes. Made off the main actor, so
    /// the handler isn't main-actor isolated (it runs on the monitor's own queue).
    nonisolated private static func watchNetwork() -> NWPathMonitor {
        let monitor = NWPathMonitor()
        monitor.pathUpdateHandler = { path in
            let up = path.status == .satisfied
            Task { @MainActor in NotesService.shared.networkChanged(up: up) }
        }
        monitor.start(queue: DispatchQueue(label: "com.dinilb.sona.network"))
        return monitor
    }

    /// The recordings that failed 3 times (in Spool/failed, `failed`) go back into the spool with no attempts and
    /// are transcribed again, and so do the ones that failed this launch: for a "Try again" on the failed banner.
    /// Returns how many came back from Spool/failed.
    @discardableResult
    func retryFailed() -> Int {
        let ids = Self.restoreFailed(in: spool)
        let again = ids + failedIDs.sorted()
        for id in again where !queue.contains(id) && current?.id != id { queue.append(id) }
        failedIDs.removeAll()
        publish()
        pump()
        return ids.count
    }

    /// Until everything that may run now has run (the debug launch and tests).
    func waitUntilIdle() async {
        while !ready || feeding { try? await Task.sleep(for: .milliseconds(100)) }
    }

    /// Registers the charging-time task. Must be called before the app finishes launching.
    nonisolated static func registerBackgroundTask() {
        BackgroundProcessing.register()
    }

    // MARK: setting up

    private func setUp() async {
        await use(await Task.detached { NotesLocation.resolve() }.value)
        enrichInForeground()
        if FileManager.default.fileExists(atPath: Paths.models.path) { Self.excludeFromBackup(Paths.models) }
        Self.retryFailedIfNewBuild(Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String, in: spool)
        recover(onlyClosed: false)
        ready = true
        publish()
        pump()
        ensureModels()
    }

    /// Writes notes to `found` from now on; notes waiting in staging move into it. At launch and on each foreground
    /// (and when the choice or the iCloud account changes) it also deletes the audio the audio setting doesn't keep.
    private func use(_ found: NotesLocation) async {
        let old = location
        if found != old {
            if let old { Log.note("notes folder: \(old.kind.rawValue) -> \(found.kind.rawValue)") }
            location = found
            // iCloud turned off or on, another account: the log's copy looks for the container again.
            DiagnosticsLog.forgetContainer()
            // Notes that must wait in staging are in backups meanwhile; once they can move, staging is out again.
            let backedUp = Self.stagingBackedUp(found)
            await Task.detached { Self.excludeFromBackup(NotesLocation.stagingFolder, !backedUp) }.value
            // Notes are always written in staging first and moved to `found` only once they're whole (the m4a made,
            // the WAV gone): a synced folder never sees a half-written note or a 115 MB/hour WAV, so neither iCloud
            // nor the Mac's import picks one up.
            if let processor {
                await processor.update(settings: processorSettings)
            } else {
                processor = Processor(spool: spool, settings: processorSettings)
                // Recordings come one at a time from `feed`: keep the models between them, let them go when it's done.
                await processor?.keepEngineLoaded(true)
            }
        }
        await claimStaging()
        // Notes go somewhere else now: the old picked folder's access stops (its notes stay there), only here, with
        // staging claimed, so a move into it is never cut off mid-note.
        if found.kind != .picked {
            PickedFolder.stopAccess()
        } else if old?.folder != found.folder {
            PickedFolder.stopRetiredAccess()
        }
        // WAVs a stopped app didn't convert: in the folder from before notes were written in staging first, and in
        // staging when notes wait there (otherwise moving them converts them first, see NotesLocation.moveNotes).
        let staging = NotesLocation.stagingFolder.appendingPathComponent("Conversations", isDirectory: true)
        let folders = found.kind == .local ? [staging] : [found.conversations]
        await Task.detached {
            for md in folders.flatMap({ AudioCompressor.leftovers(in: $0) }) { Self.compress(md) }
        }.value
        await publishLocalNotes()
        await sweepAudio(refreshing: false)
        releaseStaging()
        await refresh()
    }

    /// Moves the finished notes in staging to where notes go (nothing to do while they wait in staging).
    private func publishLocalNotes() async {
        guard let found = location, found.kind != .local else { return }
        let local = NotesLocation.stagingFolder, folder = found.folder, move = found.mover
        let moved = await Task.detached { () -> [String: URL] in
            var moved: [String: URL] = [:]
            NotesLocation.moveNotes(from: local, to: folder, move: move, moved: { moved[$0.standardizedFileURL.path] = $1 })
            return moved
        }.value
        movedNotes.merge(moved) { _, new in new }
    }

    /// Where a listed note is now: at `url` (or iCloud's stub of it), else where it moved out of staging (`moved`, by
    /// its staging `.md` path). Nil when it's in neither.
    nonisolated static func whereNow(_ url: URL, moved: [String: URL]) -> URL? {
        if NoteFiles.exists(url) { return url }
        if let there = moved[url.standardizedFileURL.path], NoteFiles.exists(there) { return there }
        return nil
    }

    /// The Processor writes into staging, and keeps a note's audio unless the setting is "Delete once transcribed".
    private var processorSettings: Settings {
        Settings(
            notesFolder: NotesLocation.stagingFolder.path, model: Self.model,
            keepAudio: audioPolicy != .deleteAfterTranscribing)
    }

    /// Where the audio setting applies: staging and where notes go now (not a place notes went before).
    private var audioFolders: [URL] {
        var out = [NotesLocation.stagingFolder.appendingPathComponent("Conversations", isDirectory: true)]
        if let location, location.kind != .local { out.append(location.conversations) }
        return out
    }

    /// Deletes the audio the setting doesn't keep (`AudioRetention`), then lists the notes again if any went.
    private func sweepAudio(refreshing: Bool = true) async {
        let folders = audioFolders, policy = audioPolicy
        // Not before onboarding has shown the audio choice: an install from before v1 kept every note's audio, and
        // the default (30 days) would delete the older ones before he'd seen it.
        guard policy != .forever, V1Settings.onboardingDone else { return }
        let removed = await Task.detached { AudioRetention.sweep(folders, policy: policy) }.value
        if removed > 0, refreshing { await refresh() }
    }

    /// Takes staging for converting, titling, moving, deleting or editing notes there, one job at a time (waits for
    /// the one now: they're short, it's never a transcription). Pair with `releaseStaging`; never nest.
    private func claimStaging() async {
        while stagingBusy { try? await Task.sleep(for: .milliseconds(100)) }
        stagingBusy = true
    }

    private func releaseStaging() {
        stagingBusy = false
    }

    /// Everything in the spool not queued yet. `onlyClosed`: not entries left open by a crash (only at launch are
    /// those surely not being recorded). The one recording now is always skipped, and so are the ones that failed
    /// this launch (`retry` brings one back).
    private func recover(onlyClosed: Bool) {
        let recording = spool.openID
        let entries = spool.pending().filter {
            (!onlyClosed || $0.closed) && $0.id != recording && !failedIDs.contains($0.id)
        }
        for entry in entries where !queue.contains(entry.id) && current?.id != entry.id { queue.append(entry.id) }
        publish()
    }

    // MARK: the queue

    private func pump() {
        guard ready, !feeding else {
            // A recording queued while the feed is finishing (unloading the models) would otherwise wait for the next
            // launch or charge: the feed looks again when it's done.
            if feeding { pumpAgain = true }
            return
        }
        feeding = true
        Task {
            await feed()
            feeding = false
            // Queued while the feed was winding down: go again now, before its background time or a task is given
            // back (`stoppedFeeding`), or it would wait for the next launch.
            if pumpAgain {
                pumpAgain = false
                pump()
                return
            }
            stoppedFeeding()
        }
    }

    private func feed() async {
        while true {
            if locationCheckNeeded {
                locationCheckNeeded = false
                await use(await Task.detached { NotesLocation.resolve() }.value)
            }
            guard let processor, let id = nextID() else {
                // A backlog is done (or must wait): the models go until the next recording.
                await processor?.unload()
                return
            }
            await process(id, with: processor)
        }
    }

    /// The next recording that may start now: none without the models; in the background, what `gate` allows, and
    /// never one on its last attempt (a background failure must never move it to Spool/failed). In the foreground one
    /// never tried goes first, so a recording that keeps killing the app mid-transcription can't hold up the newer
    /// ones (the Processor fails it after its 3rd start that never came back).
    private func nextID() -> String? {
        guard modelState == .ready else { return nil }
        // Never while recording (`gate`). The recorder queues its recording when it stops, and the feed starts again then.
        let gate = Self.gate(
            background: appInBackground, taskRuns: processingTask != nil || continuedTask != nil,
            stopped: stopInBackground, holdLeft: holdLeft, recording: spool.openID != nil)
        if gate == .none { return nil }
        queue.removeAll { $0 == spool.openID }  // still recording: the recorder queues it again when it closes
        let spool = self.spool
        guard let index = Self.nextIndex(
            in: queue, gate: gate, tries: { spool.load($0)?.attempts ?? 0 },
            audioSeconds: { WavFile.duration(of: spool.wav($0)) }, missed: backgroundMisses)
        else {
            if case .fits(let left) = gate, !queue.isEmpty {
                Log.note("\(queue.count) recording(s) wait: none fits the \(Int(left)) s of background time left")
            }
            return nil
        }
        return queue.remove(at: index)
    }

    /// What may start now (`nextID`).
    nonisolated enum Gate: Equatable, Sendable {
        /// Any recording: Sona is on screen, or (`background`) a background task carries the feed.
        case any(background: Bool)
        /// Background time held off screen (`holdBackgroundTime`): only a short note that fits this many seconds.
        case fits(TimeInterval)
        /// Nothing until Sona is on screen or a background task runs.
        case none
    }

    /// `taskRuns`: the charging task or the off-screen task runs. `stopped`: a background failure or time running out
    /// stopped those until the foreground (`stopInBackground`). `holdLeft`: the background time left when some is held,
    /// nil when none is. `recording`: the mic is on, so nothing starts, on screen or off: the models (about a gigabyte)
    /// beside the mic raise the odds iOS ends the app mid-recording, and off screen a transcription on the CPU beside
    /// it could pass iOS's background CPU limit and end the recording with it.
    nonisolated static func gate(
        background: Bool, taskRuns: Bool, stopped: Bool, holdLeft: TimeInterval?, recording: Bool
    ) -> Gate {
        if recording { return .none }
        guard background else { return .any(background: false) }
        if taskRuns, !stopped { return .any(background: true) }
        if let holdLeft { return .fits(holdLeft) }
        return .none
    }

    /// Which of `queue` goes next under `gate` (see `nextID`). On screen the first never tried, else the first. In the
    /// background never one on its last attempt; on held background time only a short one (`heldAudioCap`) that fits
    /// the time left (`backgroundSeconds`) and hasn't already failed or run out of time in the background (`missed`).
    nonisolated static func nextIndex(
        in queue: [String], gate: Gate, tries: (String) -> Int, audioSeconds: (String) -> Double, missed: Set<String>
    ) -> Int? {
        switch gate {
        case .none:
            return nil
        case .any(let background):
            return nextIndex(in: queue, background: background, tries: tries)
        case .fits(let left):
            return queue.firstIndex { id in
                let audio = audioSeconds(id)
                return tries(id) + 1 < Processor.maxAttempts && !missed.contains(id)
                    && audio <= heldAudioCap && backgroundSeconds(audio: audio) <= left
            }
        }
    }

    /// Which of `queue` goes next: in the background the first not on its last attempt; in the foreground the first
    /// never tried, else the first.
    nonisolated static func nextIndex(in queue: [String], background: Bool, tries: (String) -> Int) -> Int? {
        if background { return queue.firstIndex { tries($0) + 1 < Processor.maxAttempts } }
        return queue.firstIndex { tries($0) == 0 } ?? queue.indices.first
    }

    /// How long a note takes off screen, where it's on the CPU (`process`): the models loading, the transcription at
    /// `ContinuedProgress.cpuSpeed`, then its m4a and the move. What held background time needs left to start one: a
    /// note iOS cuts short isn't lost (it waits), but its try is wasted.
    nonisolated static func backgroundSeconds(audio: Double) -> TimeInterval {
        backgroundLoadSeconds + max(0, audio) / ContinuedProgress.cpuSpeed + backgroundFinishSeconds
    }
    /// The longest recording held background time takes (a watch note, a quick stop from the Lock Screen). With no
    /// background task running, iOS also limits an app's CPU off screen (about 80% over a minute) and ends it past
    /// that, and a transcription on the CPU uses several cores. Core ML has no way to cap the threads it uses, so the
    /// length is the cap: a longer note waits for the charger, the screen or the task asked for at a stop.
    nonisolated static let heldAudioCap: TimeInterval = 30
    nonisolated static let backgroundLoadSeconds: TimeInterval = 6
    nonisolated static let backgroundFinishSeconds: TimeInterval = 3
    /// iOS gives about 30 s once Sona is off screen and nothing else keeps it running. `backgroundTimeRemaining` says
    /// far more (even forever) while the mic still runs, so it's never trusted for more than this.
    nonisolated static let backgroundTimeCap: TimeInterval = 30

    /// The background time left while some is held; nil when none is.
    private var holdLeft: TimeInterval? {
        guard finishHold != nil else { return nil }
        return min(Self.backgroundTimeCap, max(0, UIApplication.shared.backgroundTimeRemaining))
    }

    private func process(_ id: String, with processor: Processor) async {
        let entry = spool.load(id)
        let attempts = entry?.attempts ?? 0
        let ref = entry.map { Log.ref($0.startedAt) } ?? id
        setCurrent((id, attempts))
        transcribingID = id
        noteSawBackground = appInBackground
        busy = true
        publish()
        let before = await processor.written.count
        // In the background (a background task, or held background time), the CPU alone: iOS 27 refuses the Neural
        // Engine there without the Background Inference entitlement, and a slow note beats a failed one. Back on
        // screen, the Neural Engine.
        let onCPU = appInBackground
        currentSince = Date()
        currentSeconds = WavFile.duration(of: spool.wav(id))
        currentOnCPU = onCPU
        Log.note(
            "recording \(ref): note started \(startedHow), \(String(format: "%.1f", currentSeconds)) s of audio on the "
                + (onCPU ? "CPU" : "Neural Engine"))
        let since = Date()
        let barNow = (continuedTask?.task as? BGContinuedProcessingTask)?.progress.completedUnitCount ?? 0
        currentBase = max(0, barNow - Int64(continuedDone) * ContinuedProgress.unitsPerNote)
        await processor.useCPUOnly(onCPU)
        await processor.enqueue(id)
        await processor.waitUntilIdle()
        let written = Array(await processor.written.dropFirst(before))
        let state = await processor.current
        setCurrent(nil)
        transcribingID = nil
        // The Processor makes the folders it writes into if they're gone (Spool/failed, staging).
        Self.protectPrivateFolders(spool: spool.dir, notesBackedUp: Self.stagingBackedUp(location))
        if !written.isEmpty {
            await claimStaging()
            for note in written { await Task.detached { Self.compress(note) }.value }
            // Listed now with its first-words title: the recording's row is gone from the spool, and the title and
            // place below can take ~10 s, which left nothing on screen for the note in between.
            await refresh()
            for note in written {
                // Its place and title while it's still on this iPhone, so iCloud and the Mac only see the finished note.
                await NoteEnrichment.newNote(note, recordingID: id)
            }
            await publishLocalNotes()
            await sweepAudio(refreshing: false)
            releaseStaging()
            Log.note("recording \(ref): note done \(String(format: "%.1f", Date().timeIntervalSince(since))) s after it started")
        }
        let stillWaiting = spool.load(id) != nil || Self.isFailed(id, in: spool)
        if written.isEmpty, stillWaiting {
            lastError = state.lastError
            if noteSawBackground {
                // iOS limits the Neural Engine in the background: not the recording's fault, so not an attempt.
                Self.giveBackAttempt(id, to: attempts, in: spool)
                // It goes first in line again (nothing else would queue it before the next foreground). Started on the
                // Neural Engine while the charging task or the off-screen task runs: once more now, on the CPU.
                // Otherwise it waits for the foreground or a background task. A CPU try that fails stops here, and
                // held background time never takes it again (`backgroundMisses`), so this never loops.
                if !queue.contains(id) { queue.insert(id, at: 0) }
                if onCPU || (processingTask == nil && continuedTask == nil) { stopInBackground = true }
                if appInBackground { backgroundMisses.insert(id) }
                Log.note("recording \(ref): note didn't finish in the background; it waits")
            } else if let entry = spool.load(id), entry.attempts == attempts {
                // It never started: the Processor counts an attempt only once the models have loaded. The model is
                // the problem, not this recording.
                modelDidNotLoad()
            } else if spool.load(id) != nil {
                failedIDs.insert(id)
            }
        } else if !written.isEmpty {
            lastError = nil
        }
        // The off-screen task's bar counts a note done only now, after its m4a, title, place and move: until then it
        // keeps moving within it.
        currentSince = nil
        if continuedTask != nil, !written.isEmpty { continuedDone += 1 }
        busy = false
        // Held background time stays for the next short note, if one fits; it goes when the feed stops.
        await refresh()
    }

    /// How a note starts, for the log: on screen, or off screen and on whose time.
    private var startedHow: String {
        if !appInBackground { return "on screen" }
        if continuedTask != nil { return "off screen, on the task asked for at the stop" }
        if processingTask != nil { return "off screen, on the charging task" }
        if let left = holdLeft { return "off screen, on background time (\(Int(left)) s left)" }
        return "off screen"
    }

    private func stoppedFeeding() {
        publish()
        // Each task completes once the log's copy has caught up (`DiagnosticsLog.flush`): iOS may suspend Sona then.
        if let handle = processingTask, !busy {
            processingTask = nil
            let success = !stopInBackground
            DiagnosticsLog.flush { handle.complete(success: success) }
        }
        // The off-screen task's work is done, or something stopped it (a new recording, a background failure, notes
        // left on their last attempt): its bar goes. Full, and done, only when nothing it could take still waits.
        if let handle = continuedTask, !busy {
            continuedTask = nil
            continuedTicker?.cancel()
            continuedTicker = nil
            let success = !stopInBackground && queue.isEmpty
            if success, let task = handle.task as? BGContinuedProcessingTask {
                task.progress.completedUnitCount = task.progress.totalUnitCount
            }
            DiagnosticsLog.flush { handle.complete(success: success) }
        }
        // Something still waits (the background, or a failure for next time): try again on the next charge.
        if pending > 0, modelState == .ready {
            Task.detached { BackgroundProcessing.schedule() }
        }
        // Nothing more runs on held background time: give it back, so iOS can suspend Sona now.
        if !busy { endFinishTask() }
    }

    // MARK: background

    private func observe() {
        let center = NotificationCenter.default
        func on(_ name: Notification.Name, _ action: @escaping @MainActor (NotesService) -> Void) -> NSObjectProtocol {
            center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    if let self { action(self) }
                }
            }
        }
        observers = [
            on(UIApplication.didEnterBackgroundNotification) { $0.didEnterBackground() },
            on(UIApplication.willEnterForegroundNotification) { $0.willEnterForeground() },
            // Signed in or out of iCloud: notes may move.
            on(.NSUbiquityIdentityDidChange) { service in
                service.locationCheckNeeded = true
                service.pump()
            },
        ]
    }

    private func didEnterBackground() {
        appInBackground = true
        Self.onScreen.withLock { $0 = false }
        if busy {
            noteSawBackground = true
            // Let the note being written finish; after it, only a short one that fits the time left starts.
            holdBackgroundTime()
        }
        if pending > 0 { Task.detached { BackgroundProcessing.schedule() } }
        if downloadTask != nil, case .downloading(_, let phrase) = modelState, phrase.hasPrefix("Preparing") {
            // On to the Neural Engine prep: no background time for it (see `pauseDownload`). Stopped now, the app
            // suspends; a load already under way finishes once it's back on screen, and the prep starts again then.
            pauseDownload()
        } else if downloadTask != nil, downloadHold == .invalid {
            // The download keeps going for the time iOS gives, then stops where it is (`pauseDownload`).
            downloadHold = UIApplication.shared.beginBackgroundTask(withName: "Download the speech model") { [weak self] in
                self?.pauseDownload()
            }
        }
    }

    private func willEnterForeground() {
        appInBackground = false
        Self.onScreen.withLock { $0 = true }
        stopInBackground = false
        backgroundMisses.removeAll()
        locationCheckNeeded = true
        recover(onlyClosed: true)
        pump()
        enrichInForeground()
        endDownloadHold()
        ensureModels()
    }

    /// Places and titles notes missed (`NoteEnrichment.foreground`), with the app on screen: never in a background
    /// launch (an intent, the watch, the charging task), never holding up the feed, one run at a time.
    private func enrichInForeground() {
        guard !appInBackground, enriching == nil, let conversations = location?.conversations else { return }
        enriching = Task {
            await NoteEnrichment.foreground(conversations: conversations)
            enriching = nil
        }
    }

    /// Background time while Sona is off screen, for the note under way and for short ones that came in (`gate`). One
    /// at a time: iOS counts the app's background time as a whole, so a second hold wouldn't add any.
    private func holdBackgroundTime() {
        guard finishHold == nil else { return }
        finishHold = BackgroundTime(name: "Finish the note") { [weak self] hold in self?.holdRanOut(hold) }
        if let left = holdLeft { Log.note("background time held to write notes: \(Int(left)) s") }
    }

    /// iOS says a hold's time is up. One already being given back (`endFinishTask` waits for the log's copy) just
    /// goes; the current one means the note under way is out of time.
    private func holdRanOut(_ hold: BackgroundTime) {
        guard hold === finishHold else { return }
        backgroundTimeRanOut()
    }

    /// Out of background time mid-note: it's tried again later, and this try doesn't count. With a background task
    /// running (the off-screen one or the charging one), that task carries the note on: only the borrowed time ends.
    private func backgroundTimeRanOut() {
        guard !Self.aTaskCarriesOn(continued: continuedTask != nil, charging: processingTask != nil) else {
            endFinishTask(now: true)
            return
        }
        stopInBackground = true
        if let current {
            Self.giveBackAttempt(current.id, to: current.attempts, in: spool)
            // A note that didn't fit this time won't on the next stretch either: it waits for a task or the foreground.
            backgroundMisses.insert(current.id)
            let ref = spool.load(current.id).map { Log.ref($0.startedAt) } ?? current.id
            Log.note("recording \(ref): background time ran out mid-note; it waits")
        }
        // No time to wait for the log's copy: it's started, and the next launch copies whatever it missed.
        DiagnosticsLog.copyNow()
        endFinishTask(now: true)
        Task.detached { BackgroundProcessing.schedule() }
    }

    /// When held background time runs out: a background task running carries the note on, so only the borrowed time
    /// goes; with none, the note under way is out of time (its try given back, `stopInBackground`).
    nonisolated static func aTaskCarriesOn(continued: Bool, charging: Bool) -> Bool {
        continued || charging
    }

    /// Gives the held background time back. Off screen it goes once the log's copy in iCloud has caught up (a few
    /// seconds at most, `DiagnosticsLog.flush`), so the Mac sees how this stretch went before iOS suspends Sona;
    /// `now` when iOS says time is up. A recording that comes in meanwhile holds time of its own.
    private func endFinishTask(now: Bool = false) {
        guard let hold = finishHold else { return }
        finishHold = nil
        if now { hold.end() } else { DiagnosticsLog.flush { hold.end() } }
    }

    /// The charging task started: transcribe what waits, then complete it (`stoppedFeeding`). The app may have been
    /// suspended in memory with a recording that failed or ran out of time in the background (nothing queued it again,
    /// and a resume posts no foreground), so it looks at the spool first, like coming back on screen does.
    func runProcessingTask(_ handle: BackgroundProcessing.Handle) {
        processingTask?.complete(success: false)
        processingTask = handle
        stopInBackground = false
        start()
        guard ready else { return }  // setUp recovers and pumps when it's done
        recover(onlyClosed: true)
        pump()
        if !feeding { stoppedFeeding() }
    }

    /// The charging task's time is up (the expiration handler has already given the attempt back and completed it).
    /// With the off-screen task still running, that one carries the note on and the feed goes on.
    func processingTaskExpired(_ handle: BackgroundProcessing.Handle) {
        if processingTask === handle {
            processingTask = nil
            if continuedTask == nil {
                stopInBackground = true
                if let current { Self.giveBackAttempt(current.id, to: current.attempts, in: spool) }
            }
        }
        handle.complete(success: false)
        // Started now, with no time to wait for it; the next launch copies whatever it missed.
        DiagnosticsLog.copyNow()
        Task.detached { BackgroundProcessing.schedule() }
    }

    /// The off-screen task started (it may start while the app is still on screen, or a little after he left). Like
    /// the charging task: what waits is looked for, fed, and the task completes when the feed stops
    /// (`stoppedFeeding`). A second one, from a second stop, finds this one already carrying everything.
    func runContinuedTask(_ handle: BackgroundProcessing.Handle) {
        guard continuedTask == nil else {
            handle.complete(success: true)
            return
        }
        continuedTask = handle
        continuedDone = 0
        continuedTotal = max(1, queue.count + (busy ? 1 : 0))
        currentBase = 0
        stopInBackground = false
        startContinuedTicker()
        start()
        guard ready else { return }  // setUp recovers and pumps when it's done
        recover(onlyClosed: true)
        pump()
        if !feeding { stoppedFeeding() }
    }

    /// The off-screen task was cancelled (from the Lock Screen) or iOS took its time back. The expiration handler has
    /// already given the attempt back and completed it. Off screen, the rest waits for the foreground or the next
    /// charge, as without one; on screen, or with the charging task still running, nothing changes.
    func continuedTaskExpired(_ handle: BackgroundProcessing.Handle) {
        if continuedTask === handle {
            continuedTask = nil
            continuedTicker?.cancel()
            continuedTicker = nil
            if appInBackground, processingTask == nil {
                stopInBackground = true
                if let current { Self.giveBackAttempt(current.id, to: current.attempts, in: spool) }
            }
        }
        handle.complete(success: false)
        DiagnosticsLog.copyNow()
        if pending > 0 { Task.detached { BackgroundProcessing.schedule() } }
    }

    /// Every second while the off-screen task runs: its bar, from the notes written and a guess at how far the one
    /// under way has got (`ContinuedProgress`).
    private func startContinuedTicker() {
        continuedTicker?.cancel()
        continuedTicker = Task { [weak self] in
            while !Task.isCancelled {
                guard let self, let handle = self.continuedTask else { return }
                self.showContinuedProgress(handle)
                try? await Task.sleep(for: .seconds(1))
            }
        }
    }

    private func showContinuedProgress(_ handle: BackgroundProcessing.Handle) {
        guard let task = handle.task as? BGContinuedProcessingTask else { return }
        let underWay = currentSince != nil
        continuedTotal = max(continuedTotal, continuedDone + (underWay ? 1 : 0) + queue.count)
        let share = currentSince.map {
            ContinuedProgress.share(
                elapsed: Date().timeIntervalSince($0), audioSeconds: currentSeconds, onCPU: currentOnCPU)
        } ?? 0
        let bar = ContinuedProgress.next(
            previous: task.progress.completedUnitCount, done: continuedDone, base: currentBase, share: share,
            total: continuedTotal, underWay: underWay)
        if task.progress.totalUnitCount != bar.total { task.progress.totalUnitCount = bar.total }
        task.progress.completedUnitCount = bar.completed
    }

    /// From a background task's expiration handler (the charging task or the off-screen one), off the main actor: the
    /// note being transcribed gets its attempt back now, before the task completes, because a busy main thread could
    /// otherwise run it after iOS has suspended the app and the cut-short try would count.
    /// Not when another task still carries the note, or the app is on screen and carries on with it.
    nonisolated static func backgroundTaskExpiring() {
        guard BackgroundProcessing.Handle.running.withLock({ $0 }) <= 1, !onScreen.withLock({ $0 }) else { return }
        guard let now = inFlight.withLock({ $0 }) else { return }
        giveBackAttempt(now.id, to: now.attempts, in: now.spool)
    }

    private func setCurrent(_ value: (id: String, attempts: Int)?) {
        current = value
        let spool = self.spool
        let copy = value.map { now in (id: now.id, attempts: now.attempts, spool: spool) }
        Self.inFlight.withLock { $0 = copy }
    }

    /// The models are on disk but didn't load (the Processor never got to count an attempt). The model banner says so,
    /// nothing is transcribed meanwhile, and the model is checked and repaired like after a failed download
    /// (`ensureModels`, with its back-off); once it's ready the waiting recordings are queued again.
    private func modelDidNotLoad() {
        Log.note("the speech model didn't load; checking it again")
        downloadFailures += 1
        modelState = .failed("the speech model didn't load")
        scheduleDownloadRetry()
    }

    // MARK: helpers

    private func downloadProgress(_ fraction: Double, _ phrase: String) {
        guard case .downloading = modelState else { return }
        // Downloaded off screen and on to the Neural Engine prep: stop, it runs when the app is back.
        if appInBackground, phrase.hasPrefix("Preparing") {
            pauseDownload()
            return
        }
        bestFraction = max(bestFraction, fraction)
        modelState = .downloading(fraction: bestFraction, phrase: phrase)
    }

    private func publish() {
        let recording = spool.openID
        let waiting = spool.pending(readOnly: true).filter { $0.id != recording }
        pending = waiting.count
        failed = spool.failedCount()
        // A failed id that left the spool (deleted, written, moved to Spool/failed) isn't a failed row any more.
        let ids = Set(waiting.map(\.id))
        if !failedIDs.isSubset(of: ids) { failedIDs.formIntersection(ids) }
        // `pending` keeps counting the failed ones (it decides the charging-task retry); the widget doesn't: they
        // aren't waiting for anything.
        let latest = notes.first
        WidgetStatus.publish(
            waiting: max(0, pending - failedIDs.count), latestTitle: latest?.displayTitle, latestAt: latest?.startedAt)
    }

    /// A note's file read whole (nil if it isn't here).
    nonisolated static func read(_ url: URL) -> ConversationNote? {
        try? NoteStore(root: url.deletingLastPathComponent().deletingLastPathComponent()).read(url: url)
    }

    /// A note read through NSFileCoordinator, so a rewrite iCloud is bringing in is never read half done.
    nonisolated static func readCoordinated(_ url: URL) -> ConversationNote? {
        var coordination: NSError?
        var note: ConversationNote?
        NSFileCoordinator().coordinate(readingItemAt: url, options: [], error: &coordination) { readable in
            note = try? NoteStore(root: url.deletingLastPathComponent().deletingLastPathComponent()).read(url: readable)
        }
        return note
    }

    /// iCloud evicted `file` from this iPhone: only its hidden `.<name>.icloud` stub is here.
    nonisolated static func isEvicted(_ file: URL) -> Bool {
        let fm = FileManager.default
        let stub = file.deletingLastPathComponent().appendingPathComponent(".\(file.lastPathComponent).icloud")
        return !fm.fileExists(atPath: file.path) && fm.fileExists(atPath: stub.path)
    }

    /// `file` is on this iPhone: it was, or iCloud downloaded it within `seconds`. False if it isn't anywhere, or
    /// didn't come in time (offline), or the task waiting was cancelled (a note page left). Never blocks on iCloud for
    /// longer.
    nonisolated static func fetchFromICloud(_ file: URL, waitingUpTo seconds: Double) async -> Bool {
        let fm = FileManager.default
        if fm.fileExists(atPath: file.path) { return true }
        guard isEvicted(file) else { return false }
        try? fm.startDownloadingUbiquitousItem(at: file)
        let deadline = Date().addingTimeInterval(seconds)
        // Cancelled, the sleep below returns at once: without this it would spin until the deadline.
        while Date() < deadline, !Task.isCancelled {
            try? await Task.sleep(for: .milliseconds(250))
            if fm.fileExists(atPath: file.path) { return true }
        }
        return false
    }

    /// Converts a note's kept WAV to m4a; on failure the WAV stays (and is tried again next launch).
    nonisolated static func compress(_ note: URL) {
        do { try AudioCompressor.compress(note: note) } catch {
            Log.note("couldn't make a note's audio an m4a, the wav stays: \(Log.describe(error))")
        }
    }

    nonisolated static func isFailed(_ id: String, in spool: Spool) -> Bool {
        FileManager.default.fileExists(atPath: spool.failedDir().appendingPathComponent(id + ".json").path)
    }

    /// Puts a recording back as it was before an attempt that doesn't count, out of Spool/failed if that attempt was
    /// its last.
    nonisolated static func giveBackAttempt(_ id: String, to attempts: Int, in spool: Spool) {
        if spool.load(id) == nil, isFailed(id, in: spool) {
            moveBack(id, in: spool)
            Log.note("\(id) back from Spool/failed: its last try was cut short in the background")
        }
        guard var entry = spool.load(id), entry.attempts > attempts else { return }
        entry.attempts = attempts
        spool.save(entry, durable: true)
    }

    /// Every recording in Spool/failed (its audio, its entry) back into the spool with `attempts` (0: three more tries,
    /// for "Try again"), for the Processor to take again. Returns their ids, oldest first.
    @discardableResult
    nonisolated static func restoreFailed(in spool: Spool, attempts: Int = 0) -> [String] {
        let fm = FileManager.default
        let names = (try? fm.contentsOfDirectory(atPath: spool.failedDir().path)) ?? []
        // By its audio, like `failedCount`: an entry with no audio has nothing to transcribe.
        let ids = names.filter { $0.hasSuffix(".wav") && !$0.hasSuffix(".mac.wav") && !$0.hasPrefix(".") }
            .map { String($0.dropLast(4)) }.sorted()
        var back: [String] = []
        for id in ids where !fm.fileExists(atPath: spool.wav(id).path) {
            moveBack(id, in: spool)
            guard fm.fileExists(atPath: spool.wav(id).path) else { continue }
            if var entry = spool.load(id), entry.attempts != attempts {
                entry.attempts = attempts
                spool.save(entry, durable: true)
            }
            back.append(id)
        }
        if !back.isEmpty { Log.note("\(back.count) recording(s) back from Spool/failed to be tried again") }
        return back
    }

    /// A recording's files from Spool/failed back into the spool.
    nonisolated private static func moveBack(_ id: String, in spool: Spool) {
        let fm = FileManager.default
        for name in [id + ".wav", id + ".mac.wav", id + ".json"] {
            let from = spool.failedDir().appendingPathComponent(name)
            if fm.fileExists(atPath: from.path) { try? fm.moveItem(at: from, to: spool.dir.appendingPathComponent(name)) }
        }
    }

    /// At launch: a new build may fix what made recordings fail, so what's in Spool/failed goes back into the spool
    /// once per build (`setUp` then queues it) for one more try, not three: one that still kills the app costs one
    /// crashed launch per build, not three. Returns the ids that came back.
    @discardableResult
    nonisolated static func retryFailedIfNewBuild(
        _ build: String?, in spool: Spool, defaults: UserDefaults = .standard
    ) -> [String] {
        isNewBuild(build, defaults: defaults) ? restoreFailed(in: spool, attempts: Processor.maxAttempts - 1) : []
    }

    /// True the first time it's called with a build (`CFBundleVersion`) other than the one it saw last, the first
    /// build it ever sees included. Remembers `build`.
    nonisolated static func isNewBuild(_ build: String?, defaults: UserDefaults = .standard, key: String = "lastLaunchedBuild") -> Bool {
        guard let build, !build.isEmpty else { return false }
        guard defaults.string(forKey: key) != build else { return false }
        defaults.set(build, forKey: key)
        return true
    }

    /// The spool (raw audio, Spool/failed with it) and staging (notes before they move to where notes go) stay on this
    /// iPhone: out of iCloud Backup and local backups (a folder's flag covers what's in it), and readable only once
    /// the phone has been unlocked since it started. Not `.complete`: recording and transcribing run with the phone
    /// locked. Makes the folders if they're missing, so what's written into them later is covered. The "On this
    /// iPhone" place (`NotesLocation.iPhoneFolder`) is a different folder, and is backed up. `notesBackedUp`: notes
    /// wait in staging with nowhere to go yet (`stagingBackedUp`), so it's in backups for now.
    nonisolated static func protectPrivateFolders(
        spool: URL = Paths.spool, notes: URL = Paths.defaultNotesFolder, notesBackedUp: Bool = false
    ) {
        for folder in [spool, spool.appendingPathComponent("failed", isDirectory: true), notes] {
            Paths.ensure(folder)
            excludeFromBackup(folder, folder == notes ? !notesBackedUp : true)
            try? FileManager.default.setAttributes(
                [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication], ofItemAtPath: folder.path)
        }
    }

    /// Staging is in backups only while notes wait there (nothing chosen yet, iCloud off, the folder out of reach):
    /// they may wait for weeks as this iPhone's only copy, and a lost phone mustn't take them along. Otherwise they
    /// only pass through it.
    nonisolated static func stagingBackedUp(_ location: NotesLocation?) -> Bool {
        location?.kind == .local
    }

    nonisolated static func excludeFromBackup(_ url: URL, _ excluded: Bool = true) {
        var url = url
        var values = URLResourceValues()
        values.isExcludedFromBackup = excluded
        try? url.setResourceValues(values)
    }
}
