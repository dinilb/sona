import ActivityKit
import AVFoundation
import Foundation
import NotesKit
import Observation
import os
import SonaEngine
import UIKit
import WidgetKit

/// Records voice notes on the iPhone into the app's one spool (`Services.spool`), where the processor turns them into
/// notes. It needs nothing from the UI: the Start Recording intent can launch the app in the background straight into
/// `start()`. While it records, a Live Activity shows (iOS requires one for a recording an intent started) and the
/// widgets and Control Center button say so. When the mic pauses (a call, Siri) they say "paused" instead, and a
/// notification follows if it doesn't come back soon; when it stops by itself they say why.
@MainActor @Observable
final class PhoneRecorder {
    static let shared = PhoneRecorder(
        spool: Services.spool, status: .appGroup, notices: RecordingNotices(center: SystemNoticeCenter()),
        places: .shared)

    /// With less free space than this it won't start, and a recording stops by itself.
    static let minFreeBytes: Int64 = 200_000_000
    /// While it records the Live Activity is updated this often, and each update goes stale `staleAfter` later: if the
    /// app dies, or iOS suspends it while a call has the mic, the Lock Screen stops counting within a minute and a half.
    static let heartbeatSeconds: TimeInterval = 60
    static let staleAfter: TimeInterval = 90
    /// How often the Live Activity's voice wave moves while the app is off screen (the only time anyone sees it). Each
    /// update carries the last 4 s of levels (`ActivityWave.count`), so every one shows seconds the last didn't. A Live
    /// Activity can't animate by itself, and each update wakes the widget extension, so not faster.
    static let waveSeconds: TimeInterval = 4

    private(set) var isRecording = false
    private(set) var startedAt: Date?
    /// Set while the mic is paused (a call or Siri has it, or it hasn't come back after one); nil while it hears.
    private(set) var pausedAt: Date?
    /// The last 8 s of loudness (0...1, 10 a second) with when each was heard: the live waveform.
    private(set) var wave = WaveScroll()
    /// The levels alone, newest last.
    var levels: [Float] { wave.levels }
    /// Why recording failed to start or stopped by itself, or that the mic is paused by a call; nil when all is well
    /// (a normal stop clears it, and so does the next start).
    private(set) var lastError: String?
    /// Called with the spool id once a recording is closed in the spool (not for one too short to keep).
    @ObservationIgnored var onFinished: ((String) -> Void)?
    /// How often the audio is flushed to the disk itself (tests use less).
    @ObservationIgnored var checkpointSeconds = SpoolRecording.defaultCheckpointSeconds
    /// Someone can see the waveform (the app is on screen). Off, the audio thread doesn't wake the main actor 10 times
    /// a second for levels nobody draws: the phone locked in a pocket for an hour of recording does no UI work at all.
    nonisolated static let levelsWanted = OSAllocatedUnfairLock(initialState: true)
    /// The last few seconds of levels for the Live Activity's wave, kept on the audio thread whether or not the app is
    /// on screen: a lock and a short array, with no hop to the main actor until an update reads them.
    nonisolated let waveLevels = WaveLevels()

    /// Makes the audio source for a recording; tests pass their own.
    typealias SourceFactory = @Sendable (CaptureHandlers) -> any AudioSource

    private enum Phase { case idle, starting, recording, stopping }

    @ObservationIgnored private let spool: Spool
    @ObservationIgnored private let showsActivity: Bool
    @ObservationIgnored private let status: WidgetStatus.Store?
    @ObservationIgnored private let notices: RecordingNotices?
    @ObservationIgnored private let makeSource: SourceFactory?
    @ObservationIgnored private var phase = Phase.idle
    @ObservationIgnored private var stopRequested = false
    @ObservationIgnored private var stopping: Task<Void, Never>?
    @ObservationIgnored private var source: (any AudioSource)?
    @ObservationIgnored private var recording: SpoolRecording?
    @ObservationIgnored private var activityID: String?
    /// When the current Live Activity was requested: iOS ends one after 8 hours (`ActivityLife`).
    @ObservationIgnored private var activityStartedAt: Date?
    /// Listens for iOS ending the current Live Activity (swiped away, the 8-hour limit) while it still records.
    @ObservationIgnored private var activityWatch: Task<Void, Never>?
    @ObservationIgnored private let places: PlaceStamps?
    @ObservationIgnored private var observers: [NSObjectProtocol] = []
    @ObservationIgnored private var diskWatch: Task<Void, Never>?
    @ObservationIgnored private var heartbeat: Task<Void, Never>?
    /// Moves the Live Activity's wave on while the app is off screen (`beatWave`).
    @ObservationIgnored private var waveBeat: Task<Void, Never>?
    /// The last wave sent was silence: another silent one would draw the same flat line, so it isn't sent.
    @ObservationIgnored private var waveWasQuiet = false
    /// The last Live Activity update, so the next one (or the end) waits for it: they land in order.
    @ObservationIgnored private var activityUpdate: Task<Void, Never>?
    /// Background time held while a pause reaches the Live Activity.
    @ObservationIgnored private var pauseHold = UIBackgroundTaskIdentifier.invalid

    /// `showsActivity`: the Live Activity (off in tests). `status`: where the widgets read whether it's recording
    /// (nil: nowhere). `notices`: notifications when it stops hearing (nil: none). `places`: where each recording
    /// started and stopped (nil: nowhere, as in tests, which must never ask for location). `makeSource`: nil for the
    /// mic (or, in the simulator and with `-debugRecordFile`, a file).
    init(
        spool: Spool, showsActivity: Bool = true, status: WidgetStatus.Store? = nil, notices: RecordingNotices? = nil,
        places: PlaceStamps? = nil, makeSource: SourceFactory? = nil
    ) {
        self.spool = spool
        self.showsActivity = showsActivity
        self.status = status
        self.notices = notices
        self.places = places
        self.makeSource = makeSource
        if showsActivity || places != nil {
            observers.append(NotificationCenter.default.addObserver(
                forName: UIApplication.didBecomeActiveNotification, object: nil, queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated { self?.becameActive() }
            })
        }
        // A crash or kill mid-recording leaves the widgets saying it's recording, and its Live Activity up. Its audio
        // is safe in the spool (the processor recovers it). Said in the app, so a launch from the widget explains why
        // nothing is counting any more.
        if status?.load().recordingSince != nil {
            lastError = "Sona was closed while it was recording. What it recorded up to then is saved."
        }
        publishStatus()
        if showsActivity { endLeftoverActivities() }
        // Nothing records yet in this process, so a "still recording" notice scheduled (8 hours on) or showing is from
        // one that died mid-recording: taken back before it says the mic is on when it isn't. A start right after
        // (an intent launch) posts its own after this, in order.
        notices?.activityGone()
    }

    /// Starts recording. Does nothing if it already is. Throws if the mic is off limits, the iPhone is nearly full,
    /// or the mic won't start.
    func start() async throws {
        if let stopping { await stopping.value }  // a stop still finishing: let it, then start a new one
        guard phase == .idle else {
            // Already recording (Siri or Back Tap again): if iOS ended its Live Activity, this brings the Lock Screen's
            // Stop back. An intent may start one from the background.
            if phase == .recording { restoreActivity() }
            return
        }
        phase = .starting
        stopRequested = false
        do {
            try await begin()
        } catch {
            phase = .idle
            lastError = Self.describe(error)
            Log.note("recording couldn't start: \(Log.describe(error))")
            throw error
        }
        if stopRequested { await stop() }
    }

    /// Stops and keeps the recording (a blip under half a second is deleted). Does nothing if it isn't recording.
    func stop() async {
        await end(because: nil)
    }

    /// It stops by itself (a write failed, the disk is nearly full): it keeps what's there, and says why on the Live
    /// Activity, in a notification and in the app.
    func stop(because reason: StopReason) async {
        guard phase == .recording else { return }
        await end(because: reason)
        lastError = reason.message
    }

    private func end(because reason: StopReason?) async {
        switch phase {
        case .idle:
            return
        case .starting:
            stopRequested = true  // start() stops it as soon as it's going
            return
        case .stopping:
            await stopping?.value
            return
        case .recording:
            // .stopping now, in this turn: a second stop (the Stop intent and a tap, the disk watcher and a tap) that
            // lands before the task runs waits for this one instead of closing the recording a second time.
            phase = .stopping
            let task = Task { await close(because: reason) }
            stopping = task
            await task.value
            // A newer stop may have taken the slot meanwhile; only clear our own.
            if stopping == task { stopping = nil }
        }
    }

    // MARK: Start and stop

    private func begin() async throws {
        let kind = makeSource == nil ? Self.defaultSource() : nil
        if case .mic = kind { try await Self.askForMic() }
        if let free = Self.freeBytes(at: spool.dir), free < Self.minFreeBytes { throw RecordingError.lowDisk }

        let now = Date()
        let recording = try SpoolRecording(
            spool: spool, startedAt: now, source: "iPhone", checkpointSeconds: checkpointSeconds,
            onFailure: Self.failureHandler(self))
        let handlers = Self.handlers(self, id: recording.id, recording: recording)
        let source: any AudioSource
        switch kind {
        case .mic: source = MicCapture(handlers: handlers)
        case .file(let url): source = FileAudioSource(file: url, handlers: handlers)
        case nil: source = makeSource!(handlers)
        }
        waveLevels.reset()
        waveWasQuiet = false
        // A note playing stops before the session turns to play and record: the mic would record it.
        AudioPlayer.pauseForRecording()
        // The Live Activity first: iOS only lets an intent start the mic in the background while one is up.
        if showsActivity { startActivity(at: now) }
        do {
            try source.start()
        } catch {
            recording.discard()
            await endActivity(startedAt: now, stoppedAt: nil)
            throw error
        }
        self.recording = recording
        self.source = source
        phase = .recording
        isRecording = true
        startedAt = now
        wave = WaveScroll()
        lastError = nil
        pausedAt = nil
        publishStatus()
        // Where it started: one location fix, never waited for (and none at all without the permission).
        places?.stampStart(recordingID: recording.id)
        // Asked on screen only: a recording the Lock Screen started has nowhere to show the question.
        notices?.recordingStarted(canAsk: UIApplication.shared.applicationState != .background)
        watchDisk()
        beatHeart()
        beatWave()
        Log.note("recording \(Log.ref(now)) started (\(kind.map { "\($0)" } ?? "test source"))")
    }

    /// `reason`: it stopped by itself, and the Live Activity and a notification say why instead of "saved".
    private func close(because reason: StopReason?) async {
        // end() set .stopping already: with nothing to close it must still go back to idle, or no stop or start
        // would ever get past it again.
        guard let recording else {
            phase = .idle
            return
        }
        phase = .stopping
        // Off screen (the Lock Screen, Siri, the Action button), the mic is what keeps Sona running: once it stops,
        // iOS may suspend the app before the recording is closed and handed on. Background time until it's queued,
        // where the notes service holds its own to write a short note now (`NotesService.enqueue`).
        let offScreen = UIApplication.shared.applicationState == .background
        let hold = offScreen ? BackgroundTime(name: "Close the recording") : nil
        defer { hold?.end() }
        diskWatch?.cancel()
        diskWatch = nil
        heartbeat?.cancel()
        heartbeat = nil
        waveBeat?.cancel()
        waveBeat = nil
        source?.stop()
        source = nil
        let kept = await recording.finish()
        self.recording = nil
        // Where it stopped: a fix asked for now and saved when it comes, never holding up the note (its place is
        // written once it's there). A recording too short to keep has no note, so its start fix goes too.
        if kept != nil { places?.stampStop(recordingID: recording.id) } else { places?.discard(recordingID: recording.id) }
        let started = startedAt ?? recording.startedAt
        isRecording = false
        startedAt = nil
        pausedAt = nil
        // A normal stop ends whatever was wrong while it ran (the "paused while a call has the mic" message would
        // otherwise stay under the button). A stop with a reason sets its own message once this returns.
        if reason == nil { lastError = nil }
        if let kept {
            Log.note("recording \(Log.ref(started)) saved: \(String(format: "%.1f", kept)) s, stopped \(offScreen ? "off" : "on") screen")
        } else {
            Log.note("recording \(Log.ref(started)) dropped: under \(SpoolRecording.minSeconds) s")
        }
        notices?.stopped(because: reason?.notice)
        if showsActivity { await endActivity(startedAt: started, stoppedAt: Date(), reason: reason?.short) }
        publishStatus()
        phase = .idle
        if kept != nil { onFinished?(recording.id) }
    }

    // MARK: From the audio thread (each hop to the main actor carries the recording's id, so a late one is ignored)

    /// `heard`: the frame's time (`AudioFrame.time`). When it lands here is the other half the wave needs.
    private func add(_ level: Float, heard: TimeInterval, for id: String) {
        guard recording?.id == id, phase == .recording else { return }
        wave.add(level, heard: heard, arrived: Date().timeIntervalSinceReferenceDate)
    }

    private func captureChanged(_ state: CaptureState, at time: Date, for id: String) {
        guard recording?.id == id, phase == .recording else { return }
        switch state {
        case .running:
            guard pausedAt != nil else { return }
            lastError = nil
            pausedAt = nil
            // The seconds before the pause aren't the voice now: the wave starts again from the mic coming back.
            waveLevels.reset()
            waveWasQuiet = false
            Log.note("recording: the mic is back")
            notices?.resumed()
            showState()
        case .interrupted:
            lastError = "Paused while a call or another app has the mic. It carries on by itself."
            pause(at: time)
        case .needsResume:
            lastError = "The mic hasn't come back yet. Open Sona to carry on recording."
            pause(at: time)
        case .stopped, .error:
            break
        }
    }

    /// The mic stopped hearing: the Live Activity and the widgets stop counting and say "paused", and he's notified
    /// if it doesn't come back soon. Kept from the first word of it, however often the mic repeats it.
    private func pause(at time: Date) {
        guard pausedAt == nil else { return }
        pausedAt = time
        Log.note("recording: the mic is paused")
        notices?.paused()
        // With the mic gone, iOS may suspend the app any moment: a little background time gets the word out first.
        if showsActivity, activityID != nil, pauseHold == .invalid {
            pauseHold = UIApplication.shared.beginBackgroundTask(withName: "Show the pause") { [weak self] in
                self?.releasePauseHold()
            }
        }
        showState()
    }

    private func releasePauseHold() {
        guard pauseHold != .invalid else { return }
        UIApplication.shared.endBackgroundTask(pauseHold)
        pauseHold = .invalid
    }

    /// Built outside the main actor on purpose: these closures run on the audio thread, and one isolated to the main
    /// actor would crash there.
    nonisolated private static func handlers(_ recorder: PhoneRecorder, id: String, recording: SpoolRecording) -> CaptureHandlers {
        CaptureHandlers(
            frame: { frame in
                recording.append(frame)
                let level = AudioLevel.unit(frame.levelDB)
                recorder.waveLevels.add(level)
                guard levelsWanted.withLock({ $0 }) else { return }
                let heard = frame.time
                Task { @MainActor in recorder.add(level, heard: heard, for: id) }
            },
            state: { state, _ in
                let time = Date()
                Task { @MainActor in recorder.captureChanged(state, at: time, for: id) }
            })
    }

    nonisolated private static func failureHandler(_ recorder: PhoneRecorder) -> @Sendable (Error) -> Void {
        { error in
            let full = (error as NSError).code == NSFileWriteOutOfSpaceError || (error as? POSIXError)?.code == .ENOSPC
            Log.note("recording: couldn't write the audio: \(Log.describe(error))")
            Task { @MainActor in
                await recorder.stop(because: full ? .outOfSpace : .writeFailed)
            }
        }
    }

    // MARK: Where the audio comes from

    enum SourceKind: CustomStringConvertible {
        case mic
        /// nil: silence.
        case file(URL?)

        var description: String {
            switch self {
            case .mic: "mic"
            case .file(let url): url == nil ? "silence" : "debug file"
            }
        }
    }

    /// The mic on an iPhone. In the simulator (whose mic is the Mac's) never the mic: the `-debugRecordFile` audio,
    /// or silence.
    static func defaultSource() -> SourceKind {
        if let file = RecordingDebug.recordFile { return .file(file) }
        #if targetEnvironment(simulator)
        return .file(nil)
        #else
        return .mic
        #endif
    }

    private static func askForMic() async throws {
        let permission = AVAudioApplication.shared.recordPermission
        let step = micStep(
            granted: permission == .granted, denied: permission == .denied,
            inBackground: UIApplication.shared.applicationState == .background)
        switch step {
        case .go: return
        case .denied: throw RecordingError.micDenied
        case .notAsked: throw RecordingError.micNotAsked
        case .ask: guard await AVAudioApplication.requestRecordPermission() else { throw RecordingError.micDenied }
        }
    }

    nonisolated enum MicStep: Equatable, Sendable { case go, ask, denied, notAsked }

    /// What a start does about the mic permission. Never asked yet, the question shows only on screen: from the
    /// background (the Lock Screen control, Siri, the Action button) it would never show, or never answer and leave
    /// the start hanging, so it fails at once with its own message (the intents carry on in the app first).
    nonisolated static func micStep(granted: Bool, denied: Bool, inBackground: Bool) -> MicStep {
        if granted { return .go }
        if denied { return .denied }
        return inBackground ? .notAsked : .ask
    }

    // MARK: Free space

    nonisolated static func freeBytes(at url: URL) -> Int64? {
        let values = try? url.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        return values?.volumeAvailableCapacityForImportantUsage
    }

    private func watchDisk() {
        diskWatch = Task { [weak self] in
            while !Task.isCancelled {
                // A recording grows about 2 MB a minute and a failed write stops it anyway: twice a minute is plenty.
                try? await Task.sleep(for: .seconds(30))
                guard let self, !Task.isCancelled else { return }
                if let free = Self.freeBytes(at: self.spool.dir), free < Self.minFreeBytes {
                    Log.note("recording: stopping, under 200 MB free")
                    await self.stop(because: .lowSpace)
                    return
                }
            }
        }
    }

    // MARK: Live Activity, widgets, Control Center

    /// Moves the Live Activity's stale date on once a minute while it records (and while it's paused, for as long as
    /// iOS lets the app run), and every few minutes tells the widgets it's alive. If the app dies, the activity goes
    /// stale and the widgets turn to "not recording" by themselves. It runs with Live Activities off too: the widgets'
    /// word doesn't depend on one.
    private func beatHeart() {
        heartbeat = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(Self.heartbeatSeconds))
                guard let self, !Task.isCancelled, self.phase == .recording else { return }
                self.publishStatus(alive: true)
                self.updateActivity()
                self.renewActivityIfDue()
            }
        }
    }

    /// Every `waveSeconds` while it records and the app is off screen, the Live Activity gets the last few seconds of
    /// the voice. On screen the app draws its own wave and iOS hides the activity; paused, the wave is flat anyway; and
    /// silence after silence would draw the same flat line, so none of those is sent (each update also reaches a
    /// paired watch and the Mac). The once-a-minute heartbeat still moves the stale date.
    private func beatWave() {
        guard showsActivity else { return }
        waveBeat = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(Self.waveSeconds))
                guard let self, !Task.isCancelled, self.phase == .recording else { return }
                guard self.pausedAt == nil, UIApplication.shared.applicationState != .active else { continue }
                let quiet = ActivityWave.isQuiet(ActivityWave.encode(self.waveLevels.snapshot()))
                if quiet, self.waveWasQuiet { continue }
                self.waveWasQuiet = quiet
                // A wave isn't what the pause's background time waits for: only the update that carries the pause
                // lets it go.
                self.updateActivity(releasingHold: false)
            }
        }
    }

    /// `start`: when the recording started (a renewed activity keeps the true length).
    private func startActivity(at start: Date) {
        let now = Date()
        let content = ActivityContent(
            state: RecordingAttributes.ContentState(startedAt: start), staleDate: now.addingTimeInterval(Self.staleAfter))
        do {
            let id = try Activity.request(attributes: RecordingAttributes(), content: content, pushType: nil).id
            activityID = id
            activityStartedAt = now
            watchActivity(id)
            // If it's still recording when iOS ends this activity (8 hours on), he hears about it even if the app
            // can't run then.
            notices?.activityStarted()
        } catch {
            // Recording goes on without it (Live Activities turned off in Settings, say).
            Log.note("recording: no Live Activity: \(Log.describe(error))")
        }
    }

    /// Listens for iOS ending this activity while it still records: swiped away, or the 8-hour limit.
    private func watchActivity(_ id: String) {
        activityWatch?.cancel()
        activityWatch = Task { await Self.watchActivity(id: id, recorder: self) }
    }

    /// Off the main actor, like `updateActivities`: the activity is looked up by id and only its states cross over.
    @concurrent nonisolated private static func watchActivity(id: String, recorder: PhoneRecorder) async {
        guard let activity = Activity<RecordingAttributes>.activities.first(where: { $0.id == id }) else { return }
        for await state in activity.activityStateUpdates {
            if Task.isCancelled { return }
            if state == .ended || state == .dismissed {
                await recorder.activityEnded(id: id)
                return
            }
        }
    }

    /// iOS ended the Live Activity. Its own end (`endActivity` clears the id first) and a renewal's are ignored; one
    /// that ends under a recording leaves no Stop on the Lock Screen, so he's told it's still recording, and opening
    /// the app brings it back (`restoreActivity`).
    private func activityEnded(id: String) {
        guard ActivityLife.lost(ended: true, id: id, current: activityID, recording: phase == .recording) else { return }
        activityID = nil
        activityStartedAt = nil
        activityWatch = nil
        Log.note("recording: its Live Activity was ended (swiped away or the 8-hour limit); still recording")
        notices?.activityLost()
        releasePauseHold()
    }

    /// The recording goes on but has no Live Activity (iOS ended it): a new one, with the same start, so the timer
    /// keeps the true length, and the pause if there is one. Works on screen, and from an intent in the background.
    /// Every activity up before it goes once the new one is there: one iOS ended at its 8-hour limit stays on the Lock
    /// Screen (up to 4 hours) with its last content, and a renewal's old one goes the same way. Without a new one they
    /// stay, since an ended one still has the only Stop on the Lock Screen.
    private func restoreActivity() {
        guard showsActivity, phase == .recording, activityID == nil, let startedAt,
            ActivityAuthorizationInfo().areActivitiesEnabled
        else { return }
        let leftovers = Activity<RecordingAttributes>.activities.map(\.id)
        startActivity(at: startedAt)
        guard activityID != nil else { return }
        updateActivity()
        if !leftovers.isEmpty { Task { await Self.endActivities(leftovers, state: nil) } }
    }

    /// Just before iOS's 8-hour limit, with the app on screen (a new activity can't be asked for from the background):
    /// the old activity goes and a new one comes for the same recording. No new note.
    private func renewActivityIfDue() {
        guard showsActivity, phase == .recording, let old = activityID, let since = activityStartedAt,
            ActivityLife.needsRenewal(
                age: Date().timeIntervalSince(since), appActive: UIApplication.shared.applicationState == .active)
        else { return }
        activityWatch?.cancel()
        activityWatch = nil
        activityID = nil
        activityStartedAt = nil
        // A new one ends the old one (restoreActivity ends every activity that was up before it).
        restoreActivity()
        guard activityID != nil else {
            // No new one: the old one stays until iOS ends it, and its 8-hour notice stays scheduled.
            activityID = old
            activityStartedAt = since
            watchActivity(old)
            return
        }
    }

    /// Back on screen: a Live Activity iOS ended comes back, and a location question left from a recording that
    /// stopped in the background is asked now.
    private func becameActive() {
        restoreActivity()
        places?.appBecameActive()
    }

    /// The Live Activity and the widgets show what's true now: recording, or paused since when.
    private func showState() {
        publishStatus()
        updateActivity()
    }

    /// The Live Activity shows the state as it is now, with its stale date moved on. `releasingHold`: once it lands, the
    /// background time held for a pause (`pause(at:)`) goes; a wave update in flight when the mic pauses must not let
    /// it go before the pause has gone out.
    private func updateActivity(releasingHold: Bool = true) {
        guard showsActivity, let id = activityID, let startedAt else {
            if releasingHold { releasePauseHold() }
            return
        }
        // The wave only while it hears: paused, the activity draws it flat.
        let levels = pausedAt == nil ? ActivityWave.encode(waveLevels.snapshot()) : nil
        let state = RecordingAttributes.ContentState(startedAt: startedAt, pausedAt: pausedAt, levels: levels)
        let staleDate = Date().addingTimeInterval(Self.staleAfter)
        let previous = activityUpdate
        activityUpdate = Task {
            await previous?.value
            await Self.updateActivities([id], state: state, staleDate: staleDate)
            if releasingHold { releasePauseHold() }
        }
    }

    /// `stoppedAt`: it says "saved", or with `reason` why it stopped, then goes; nil: it goes now.
    private func endActivity(startedAt: Date, stoppedAt: Date?, reason: String? = nil) async {
        // The 8-hour "still recording" notice and any "still recording" already showing are about this recording.
        notices?.activityGone()
        activityWatch?.cancel()
        activityWatch = nil
        activityStartedAt = nil
        let current = activityID
        activityID = nil
        guard showsActivity else {
            releasePauseHold()
            return
        }
        // An update still on its way lands first, so it can't replace the final state.
        let pending = activityUpdate
        activityUpdate = nil
        await pending?.value
        // The current one shows the final state. Any other goes now: one iOS ended at its 8-hour limit would stay on
        // the Lock Screen for up to 4 hours with its last content and a Stop, saying it records. With no current one
        // (stopped by Siri, say, before the app brought a new one) that's all there is to end.
        let others = Activity<RecordingAttributes>.activities.map(\.id).filter { $0 != current }
        if !others.isEmpty { await Self.endActivities(others, state: nil) }
        if let current {
            let state = RecordingAttributes.ContentState(startedAt: startedAt, stoppedAt: stoppedAt, stopReason: reason)
            await Self.endActivities([current], state: state)
        }
        releasePauseHold()
    }

    /// Off the main actor: ActivityKit's activities aren't Sendable, so they're looked up by id and updated there.
    @concurrent nonisolated private static func updateActivities(
        _ ids: [String], state: RecordingAttributes.ContentState, staleDate: Date
    ) async {
        for activity in Activity<RecordingAttributes>.activities where ids.contains(activity.id) {
            await activity.update(ActivityContent(state: state, staleDate: staleDate))
        }
    }

    /// Off the main actor, like `updateActivities`. `state` nil: they go now, as they are.
    @concurrent nonisolated private static func endActivities(_ ids: [String], state: RecordingAttributes.ContentState?) async {
        for activity in Activity<RecordingAttributes>.activities where ids.contains(activity.id) {
            guard let state, state.stoppedAt != nil else {
                await activity.end(state.map { ActivityContent(state: $0, staleDate: nil) }, dismissalPolicy: .immediate)
                continue
            }
            // Ending with the final content shows it: no separate update first. "Saved" goes after 2 s; a recording
            // that stopped by itself stays on the Lock Screen until he's seen it (the system's default, up to 4 hours).
            let policy: ActivityUIDismissalPolicy = state.stopReason == nil ? .after(Date().addingTimeInterval(2)) : .default
            await activity.end(ActivityContent(state: state, staleDate: nil), dismissalPolicy: policy)
        }
    }

    /// The widgets' part of the status: recording since when, paused since when, and when it last said it's alive (all
    /// nil when it isn't recording). Saved, and the widgets reloaded, only when it changed: reloads are budgeted. The
    /// Record control is a plain button, with nothing there to reload. `alive`: the heartbeat's word that the app still
    /// runs, so the widgets don't turn to "not recording" (`SharedStatus.staleAt`).
    private func publishStatus(alive: Bool = false) {
        guard let status else { return }
        let old = status.load()
        let new = Self.status(old, recordingSince: startedAt, pausedAt: pausedAt, alive: alive, now: Date())
        guard new != old else { return }
        status.save(new)
        status.reload()
    }

    /// `old` with the recorder's fields as they are now. `aliveAt` is set when a recording starts, and moved on only
    /// when `alive` and the last word is `SharedStatus.aliveEvery` old (each move is a widget reload).
    static func status(_ old: SharedStatus, recordingSince: Date?, pausedAt: Date?, alive: Bool, now: Date) -> SharedStatus {
        var new = old
        new.recordingSince = recordingSince
        new.pausedAt = pausedAt
        if recordingSince == nil {
            new.aliveAt = nil
        } else if old.recordingSince != recordingSince || old.aliveAt == nil {
            new.aliveAt = now
        } else if alive, let last = old.aliveAt, now.timeIntervalSince(last) >= SharedStatus.aliveEvery - 1 {
            new.aliveAt = now
        }
        return new
    }

    /// Activities a crash or kill left up. Only those up now: a recording an intent is about to start makes its own.
    private func endLeftoverActivities() {
        let stale = Activity<RecordingAttributes>.activities.map(\.id)
        guard !stale.isEmpty else { return }
        Task { await Self.endActivities(stale, state: nil) }
    }

    private static func describe(_ error: Error) -> String {
        (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
    }
}

/// The Live Activity's life under a long recording, as plain decisions (unit tested in SonaTests/V1RecordingTests.swift).
/// iOS ends an activity after 8 hours, and he can swipe one away any time; neither stops the recording.
nonisolated enum ActivityLife {
    /// iOS's limit for a Live Activity.
    static let systemLimit: TimeInterval = 8 * 3600
    /// A new activity replaces the old a little before the limit (only with the app on screen).
    static let renewAfter: TimeInterval = systemLimit - 5 * 60

    /// An activity iOS says `ended` is a lost one only if it's the current one and it's still recording: the app's own
    /// end clears the id first, and a renewal swaps it.
    static func lost(ended: Bool, id: String, current: String?, recording: Bool) -> Bool {
        ended && recording && current == id
    }

    /// `age`: how long the current activity has been up.
    static func needsRenewal(age: TimeInterval, appActive: Bool) -> Bool {
        appActive && age >= renewAfter
    }
}

/// Why a recording stopped by itself.
nonisolated enum StopReason: Sendable {
    /// A write failed with the disk full.
    case outOfSpace
    /// Under `minFreeBytes` free.
    case lowSpace
    /// A write failed some other way.
    case writeFailed

    /// In the app, under the button.
    var message: String {
        switch self {
        case .outOfSpace: "Stopped: this iPhone is out of space."
        case .lowSpace: "Stopped: less than 200 MB free on this iPhone."
        case .writeFailed: "Stopped: the recording couldn't be saved."
        }
    }

    /// On the Live Activity, after "stopped:".
    var short: String {
        switch self {
        case .outOfSpace: "out of space"
        case .lowSpace: "low on space"
        case .writeFailed: "couldn't save"
        }
    }

    /// The notification.
    var notice: String {
        switch self {
        case .outOfSpace: "This iPhone is out of space. What it recorded up to now is kept."
        case .lowSpace: "Less than 200 MB is free on this iPhone. What it recorded up to now is kept."
        case .writeFailed: "The audio couldn't be written. What it recorded up to now is kept."
        }
    }
}

nonisolated enum RecordingError: LocalizedError, LogSafeError {
    /// He said no (or turned it off): only Settings can change it.
    case micDenied
    /// Never asked yet, and a start from the background can't ask: tapping Record in the app does.
    case micNotAsked
    case lowDisk

    var errorDescription: String? {
        switch self {
        case .micDenied: "Sona can't use the microphone. Turn it on in Settings > Apps > Sona."
        case .micNotAsked: "Open Sona and tap Record once to allow the microphone."
        case .lowDisk: "There isn't enough free space to record. Sona needs 200 MB."
        }
    }
}

/// The Live Activity's last few seconds of levels (`ActivityWave.count` of them), written on the audio thread and read
/// on the main actor when an update goes out.
nonisolated final class WaveLevels: Sendable {
    private let levels = OSAllocatedUnfairLock<[Float]>(initialState: [])

    func add(_ level: Float) {
        levels.withLock { levels in
            levels.append(level)
            if levels.count > ActivityWave.count { levels.removeFirst(levels.count - ActivityWave.count) }
        }
    }

    func snapshot() -> [Float] { levels.withLock { $0 } }

    func reset() { levels.withLock { $0.removeAll() } }
}
