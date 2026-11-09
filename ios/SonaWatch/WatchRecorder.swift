import AVFoundation
import Observation
import WatchKit
import os

/// The dictaphone: one tap starts recording, one tap stops. It records AAC at 16 kHz mono (ADTS, about 14 MB an hour,
/// 8 times less to send than PCM; a WAV only if the encoder won't start), which the iPhone decodes into its spool.
/// Once started in the front it keeps going with the wrist down (`UIBackgroundModes: audio`), with no time limit but the watch's free storage (after
/// 2 hours a notification says it's still going).
///
/// It stops only when he says so, apart from three things, and each one is saved and made known:
/// - A call or Siri takes the mic. The recording is saved there and then. If the mic is back within 2 minutes with
///   Sona on screen, a new one starts (`InterruptionPolicy`); otherwise he opens Sona to carry on, because watchOS
///   won't start the mic for an app in the background.
/// - The watch runs low on storage (`DiskPolicy`).
/// - The recorder stops or fails by itself, or quietly stops writing (`HealthPolicy`, checked every minute).
/// When it can't carry on, a notification says so too: the watch is on his wrist, not in front of his eyes.
@MainActor @Observable
final class WatchRecorder {
    private(set) var isRecording = false
    private(set) var startedAt: Date?
    /// The last few seconds of input level, 0...1, ten a second, oldest first: the live waveform.
    private(set) var levels: [Float] = []
    /// The recording now being made.
    private(set) var currentID: String?
    /// A short line for the screen: why it stopped or couldn't start, or that it carried on.
    var message: String?
    /// Called when a recording starts or stops (and is saved), so the queue and the complications follow.
    @ObservationIgnored var onChange: @MainActor () -> Void = {}
    /// Called on each minute check that finds the recording still being written (the complication's heartbeat).
    @ObservationIgnored var onHealthy: @MainActor () -> Void = {}

    static let levelCount = 40

    /// The clock, and the waits, so tests can move them on.
    @ObservationIgnored var now: () -> Date = { Date() }
    /// Seconds on a clock that counts sleep and never jumps when the time is set: the health check's, so a watch whose
    /// time is set forward mid-recording doesn't look like a recorder that stopped writing.
    @ObservationIgnored var clock: () -> TimeInterval = { WatchRecorder.continuousSeconds() }
    @ObservationIgnored var checkStorageEvery: Duration = DiskPolicy.checkEvery
    /// After a call, the new recording is tried again after each of these if the mic won't start.
    @ObservationIgnored var resumeRetryDelays: [Duration] = [.seconds(2), .seconds(5)]
    /// A failed final save of a recording's length is tried again after each of these.
    @ObservationIgnored var saveRetryDelays: [Duration] = [.seconds(1), .seconds(5), .seconds(30)]

    private let store: RecordingStore
    private let platform: RecorderPlatform
    @ObservationIgnored private var capture: (any AudioCapture)?
    @ObservationIgnored private var meterTask: Task<Void, Never>?
    @ObservationIgnored private var storageTask: Task<Void, Never>?
    @ObservationIgnored private var starting = false
    @ObservationIgnored private var visible = true
    @ObservationIgnored private var interruptions = InterruptionPolicy()
    @ObservationIgnored private var interruptionObserver: (any NSObjectProtocol)?
    @ObservationIgnored private var resetObserver: (any NSObjectProtocol)?
    /// The last health check that found the recorder writing: `clock()` and the recorder's time then.
    @ObservationIgnored private var lastHealthy: (clock: TimeInterval, audio: TimeInterval)?
    private static let log = Logger(subsystem: "com.dinilb.sona.watchkitapp", category: "recorder")

    /// CLOCK_MONOTONIC on Apple platforms keeps counting while the device sleeps, and setting the time doesn't move it.
    nonisolated static func continuousSeconds() -> TimeInterval {
        TimeInterval(clock_gettime_nsec_np(CLOCK_MONOTONIC)) / 1_000_000_000
    }

    init(store: RecordingStore, platform: RecorderPlatform = .live()) {
        self.store = store
        self.platform = platform
        // A call or Siri takes the mic, and gives it back.
        interruptionObserver = platform.center.addObserver(
            forName: AVAudioSession.interruptionNotification, object: nil, queue: .main
        ) { [weak self] note in
            guard let event = Interruption(userInfo: note.userInfo) else { return }
            Task { @MainActor in await self?.interrupted(event) }
        }
        // The audio daemon restarted: the recorder is an orphan that will never write again, and no delegate call
        // says so.
        resetObserver = platform.center.addObserver(
            forName: AVAudioSession.mediaServicesWereResetNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.mediaServicesWereReset() }
        }
        platform.mic.onEvent = { [weak self] id, event in self?.recorderReported(id: id, event) }
    }

    func toggle() {
        if isRecording { stop() } else { Task { await start() } }
    }

    func start() async {
        switch await begin(resuming: false) {
        case .started, .alreadyRunning:
            break
        case .refused(let why):
            message = why
            platform.haptic(.failure)
        case .micFailed:
            message = "The mic didn't start. Try again."
            platform.haptic(.failure)
        }
    }

    /// Stops, finishes the audio file and saves its length. `note` says why, when it wasn't the user.
    func stop(saying note: String? = nil) {
        finish(note: note, keepSession: false)
    }

    // MARK: Starting

    private enum StartResult: Equatable {
        case started
        /// Recording, or a start in flight, so nothing was done.
        case alreadyRunning
        /// Won't work however often it's tried: no mic permission, or no room. `why` is the screen's line.
        case refused(why: String)
        /// The mic or the session didn't start; a moment later it may.
        case micFailed
    }

    /// Starts a new recording. `resuming` is the restart after a call or Siri.
    private func begin(resuming: Bool) async -> StartResult {
        guard !isRecording, !starting else { return .alreadyRunning }
        starting = true
        defer { starting = false }
        guard await platform.mic.requestPermission() else {
            return .refused(why: "Sona can't use the mic. Allow it in Settings, Privacy & Security, Microphone.")
        }
        guard DiskPolicy.canStart(freeBytes: platform.freeBytes(store.dir)) else {
            return .refused(why: "Watch storage is nearly full. Free some up to record.")
        }
        // From here to onChange() nothing waits, so the transfer queue never sees this recording's first JSON
        // (duration 0) without also being told it's the one being made.
        let recording = WatchRecording(startedAt: now(), duration: 0)
        do {
            try platform.mic.activateSession()
            // The JSON goes first: if the watch dies mid-recording, the next launch finds it and repairs the audio.
            try store.save(recording)
            capture = try platform.mic.startRecording(to: store.aacURL(recording.id))
        } catch {
            store.delete(recording.id)
            // Between a call and its restart the session stays on, to get the mic back.
            if !resuming, !interruptions.isWaiting { platform.mic.deactivateSession() }
            return .micFailed
        }
        currentID = recording.id
        startedAt = recording.startedAt
        levels = []
        message = resuming ? "Carried on after a call or Siri. First part saved." : nil
        isRecording = true
        interruptions.stopWaiting()
        startMeters()
        lastHealthy = (clock: clock(), audio: 0)
        startHealthChecks(for: recording.id)
        // Any "stopped" notification is out of date now.
        platform.notifier.clear()
        // Notification permission is asked when the first recording stops, not here: an alert over the Stop button
        // as he starts to talk is the wrong moment.
        platform.notifier.schedule(.mayHaveStopped, after: HealthPolicy.watchdogAfter)
        platform.notifier.schedule(.stillRecording, after: HealthPolicy.stillRecordingAfter)
        platform.haptic(.start)
        onChange()
        return .started
    }

    // MARK: Stopping

    /// Finishes the recording being made. `keepSession` leaves the audio session on (a restart is coming).
    /// `recorderGone`: the recorder is an orphan (media services were reset), so it isn't touched again, and its
    /// file, which it never finished, is repaired.
    private func finish(note: String?, keepSession: Bool, recorderGone: Bool = false) {
        guard isRecording else { return }
        meterTask?.cancel()
        meterTask = nil
        storageTask?.cancel()
        storageTask = nil
        lastHealthy = nil
        for reminder in RecordingReminder.allCases { platform.notifier.cancel(reminder) }
        if let capture, let id = currentID {
            let lastTime = recorderGone ? 0 : capture.currentTime
            if !recorderGone { capture.stop() }  // flushes the last frames (and writes a WAV's sizes)
            self.capture = nil
            if !keepSession { platform.mic.deactivateSession() }
            // An orphaned recorder never finished its file: a WAV's sizes are rebuilt, an AAC's torn frame cut off.
            let seconds = (try? store.audioSeconds(id, force: recorderGone)) ?? lastTime
            if seconds > 0 {
                var recording = store.load(id) ?? WatchRecording(id: id, startedAt: startedAt ?? now(), duration: 0)
                recording.duration = seconds
                saveLength(recording)
            } else {
                store.delete(id)  // nothing was recorded
            }
        }
        isRecording = false
        currentID = nil
        startedAt = nil
        message = note
        platform.haptic(.stop)
        // The first time only (it does nothing after), and only with him looking: so a call can be told about next
        // time.
        if visible { platform.notifier.askPermission() }
        onChange()
    }

    /// Writes the recording's length. If that fails the JSON still says 0, as if it never stopped, and the
    /// recording would stay out of sight: so it's tried again a few times, and `TransferQueue.run()` also finishes
    /// any such recording from its audio.
    private func saveLength(_ recording: WatchRecording) {
        do {
            try store.save(recording)
            return
        } catch {}
        let store = self.store
        Task { [weak self] in
            for delay in self?.saveRetryDelays ?? [] {
                try? await Task.sleep(for: delay)
                // The queue may have finished it by now (and sent it): don't write over that.
                guard let onDisk = store.load(recording.id), onDisk.duration <= 0 else { return }
                if (try? store.save(recording)) != nil {
                    self?.onChange()
                    return
                }
            }
        }
    }

    /// The recording ended and he didn't ask: keep what was recorded, say so on the screen and in a notification.
    private func stopUnasked(_ reason: UnexpectedStop, saying note: String, recorderGone: Bool = false) {
        finish(note: note, keepSession: false, recorderGone: recorderGone)
        platform.notifier.notify(reason, after: 0)
    }

    /// The recorder says it finished or failed. Only the recording being made counts: our own `stop()` of an
    /// earlier one reports in late, and must not stop the next.
    func recorderReported(id: String, _ event: RecorderEvent) {
        guard isRecording, id == currentID else { return }
        switch event {
        case .finished: stopUnasked(.recorderStopped, saying: "Recording stopped. Saved.")
        case .failed: stopUnasked(.recorderStopped, saying: "Recording hit an error. Saved what was recorded.")
        }
    }

    // MARK: Health and storage

    /// Every minute while recording: is the recorder still writing, and is there room.
    private func startHealthChecks(for id: String) {
        storageTask?.cancel()
        storageTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: self?.checkStorageEvery ?? DiskPolicy.checkEvery)
                guard !Task.isCancelled, let self, self.currentID == id else { return }
                self.checkAlive()
                self.checkStorage()
            }
        }
    }

    /// Stops and saves if the recorder quietly stopped writing: it says it isn't recording, or it wrote less than
    /// half the time that went by since the last check. Each stretch is judged on its own, so the start's latency
    /// doesn't count. While all is well, the "may have stopped" notification moves ahead again.
    func checkAlive() {
        guard isRecording, let capture, let id = currentID else { return }
        let at = clock()
        let audio = capture.currentTime
        let last = lastHealthy ?? (clock: at, audio: audio)
        let gap = at - last.clock
        if capture.isRecording {
            // No baseline yet (or a clock that went back, which a monotonic one shouldn't): start counting from here.
            if lastHealthy == nil || gap < 0 { lastHealthy = (clock: at, audio: audio) }
            // Too soon to tell (a quick wrist raise).
            if gap < HealthPolicy.judgeAfter { return }
            if !HealthPolicy.stalled(wall: gap, audio: audio - last.audio) {
                lastHealthy = (clock: at, audio: audio)
                platform.notifier.schedule(.mayHaveStopped, after: HealthPolicy.watchdogAfter)
                onHealthy()
                return
            }
        }
        // Seconds only: never what was said.
        let missing = Int(max(0, gap - max(0, audio - last.audio)).rounded())
        Self.log.notice("the recorder stopped writing (\(missing, privacy: .public) s missing); saving")
        stopUnasked(.recorderStopped, saying: "Recording stopped on its own. Saved.")
        if let seconds = store.load(id)?.duration, seconds > 0 {
            let kept = Duration.seconds(seconds.rounded(.down)).formatted(.time(pattern: .minuteSecond))
            message = "Recording stopped on its own after \(kept). Saved."
        }
    }

    /// Media services were reset: the recorder will never write again. What it wrote is kept.
    func mediaServicesWereReset() {
        guard isRecording else { return }
        Self.log.notice("media services were reset mid-recording; saving")
        stopUnasked(.recorderStopped, saying: "Recording stopped on its own. Saved.", recorderGone: true)
    }

    /// Stops and saves before the watch is full. Checked every minute while recording.
    func checkStorage() {
        guard isRecording, DiskPolicy.mustStop(freeBytes: platform.freeBytes(store.dir)) else { return }
        stopUnasked(.lowStorage, saying: "Watch storage is nearly full. Stopped and saved.")
    }

    // MARK: Interruptions

    /// A call, Siri or an alarm took the mic or gave it back.
    func interrupted(_ event: Interruption) async {
        switch interruptions.handle(event, isRecording: isRecording, now: now(), onScreen: visible) {
        case .nothing:
            break
        case .saveAndWait:
            // Saved as it is, and queued for the iPhone. The session stays on so the system can hand the mic back.
            finish(note: "A call or Siri took the mic. Saved so far.", keepSession: true)
            // If nothing has the mic back by then, say so. Scheduled now, it fires even if the app is suspended.
            platform.notifier.notify(.interrupted, after: InterruptionPolicy.notifyAfter)
        case .startNewRecording:
            await resume()
        case .leaveItToHim(let tell):
            // Off screen (watchOS won't start the mic there) or long after: no surprise recording. The line on the
            // screen already says it was saved; the normal button carries on.
            platform.mic.deactivateSession()
            if tell { platform.notifier.notify(.interrupted, after: 0) }
        }
    }

    /// Starts the new recording after a call. If it can't, he's told.
    private func resume() async {
        for delay in [Duration.zero] + resumeRetryDelays {
            if delay > .zero { try? await Task.sleep(for: delay) }
            switch await begin(resuming: true) {
            case .started, .alreadyRunning:
                return
            case .refused(let why):
                message = why
                return giveUpResuming()
            case .micFailed:
                continue
            }
        }
        message = "Couldn't carry on after a call or Siri. Saved so far."
        giveUpResuming()
    }

    private func giveUpResuming() {
        platform.mic.deactivateSession()
        platform.haptic(.failure)
        platform.notifier.notify(.couldNotResume, after: 0)
    }

    // MARK: Screen

    /// The waveform only matters on screen: off it, the meters stop to save battery (recording goes on). Back on
    /// screen, the recorder is checked at once: he's looking at the timer.
    func setVisible(_ visible: Bool) {
        self.visible = visible
        if visible { checkAlive() }
        if visible, isRecording, meterTask == nil, capture != nil {
            startMeters()
        } else if !visible, capture != nil {
            meterTask?.cancel()
            meterTask = nil
        }
    }

    private func startMeters() {
        guard visible else { return }
        meterTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self, let capture = self.capture else { return }
                self.push(Self.level(decibels: capture.decibels()))
                try? await Task.sleep(for: .milliseconds(100))
            }
        }
    }

    /// Speech sits around -40...-10 dB; below -50 is drawn flat.
    nonisolated static func level(decibels: Float) -> Float { max(0, min(1, (decibels + 50) / 50)) }

    private func push(_ level: Float) {
        levels.append(level)
        if levels.count > Self.levelCount { levels.removeFirst(levels.count - Self.levelCount) }
    }

    #if DEBUG
    /// `-debugFakeRecording`: the recording screen with a made-up waveform and no mic, for screenshots in the
    /// simulator (where recording would use the Mac's mic). Nothing is saved.
    func startFake() {
        startedAt = Date().addingTimeInterval(-192)
        isRecording = true
        levels = (0..<Self.levelCount).map { Self.fakeLevel($0) }
        meterTask = Task { [weak self] in
            var step = Self.levelCount
            while !Task.isCancelled {
                guard let self else { return }
                self.push(Self.fakeLevel(step))
                step += 1
                try? await Task.sleep(for: .milliseconds(100))
            }
        }
    }

    private static func fakeLevel(_ step: Int) -> Float {
        let syllable = abs(sin(Float(step) * 0.55)) * (0.55 + 0.4 * abs(sin(Float(step) * 0.13)))
        return step % 17 < 3 ? 0.06 : 0.12 + syllable * 0.8
    }
    #endif
}
