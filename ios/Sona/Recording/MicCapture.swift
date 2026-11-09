import AVFoundation
import NotesKit
import os
import UIKit

/// The iPhone's mic as 100 ms frames of 16 kHz mono Int16, kept going through calls, Siri, alarms and AirPods coming
/// and going. It owns the audio session and the engine, all on its own serial queue; frames are handed over on the tap's thread.
nonisolated final class MicCapture: AudioSource, @unchecked Sendable {
    private let handlers: CaptureHandlers
    private let queue = DispatchQueue(label: "com.dinilb.sona.mic")
    private let session = AVAudioSession.sharedInstance()
    private var observers: [NSObjectProtocol] = []

    // Only touched on `queue`.
    private var engine: AVAudioEngine?
    private var engineObserver: NSObjectProtocol?
    private var wantsRunning = false
    /// The input the engine was built for. A route change that leaves it as it was (AirPods connecting for playback,
    /// the input still the iPhone's mic) leaves the engine alone.
    private var builtFor: MicInput?
    /// The engine started and nothing has said the mic went away since (an interruption, a failed restart, a media
    /// services reset). Only then can a silence from the tap be a stall: the watchdog fires once per stall.
    private var hearing = false
    /// Checks every few seconds that frames still arrive (`MicWatchdog`).
    private var watchdog: DispatchSourceTimer?

    /// When the tap last delivered a buffer (`FrameMaker.monotonicNow()`). Written on the tap's thread, read on
    /// `queue`, hence the lock. Never touches the engine.
    private let lastFrame = OSAllocatedUnfairLock(initialState: FrameMaker.monotonicNow())

    /// Retries and backoff live in RecoveryLoop (unit tested); this hands it the real restart and timer. Set in init.
    private var recovery: RecoveryLoop!

    init(handlers: CaptureHandlers) {
        self.handlers = handlers
        recovery = RecoveryLoop(
            wantsRunning: { [weak self] in self?.wantsRunning ?? false },
            tryRestart: { [weak self] in
                guard let self else { return }
                try self.configureSession()
                try self.startEngine()
            },
            emit: { [weak self] state, message in
                // A miss: not hearing until a restart works (RecoveryLoop runs on `queue`).
                self?.hearing = false
                self?.handlers.state(state, message)
            },
            schedule: { [weak self] delay, run in
                let work = DispatchWorkItem(block: run)
                self?.queue.asyncAfter(deadline: .now() + delay, execute: work)
                return { work.cancel() }
            })
        let center = NotificationCenter.default
        observers = [
            center.addObserver(forName: AVAudioSession.interruptionNotification, object: session, queue: nil) { [weak self] note in
                let raw = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt
                self?.interrupted(raw.flatMap(AVAudioSession.InterruptionType.init(rawValue:)))
            },
            center.addObserver(forName: AVAudioSession.routeChangeNotification, object: session, queue: nil) { [weak self] _ in
                self?.routeChanged()
            },
            center.addObserver(forName: AVAudioSession.mediaServicesWereResetNotification, object: session, queue: nil) { [weak self] _ in
                self?.mediaServicesReset()
            },
            center.addObserver(forName: UIApplication.didBecomeActiveNotification, object: nil, queue: nil) { [weak self] _ in
                self?.becameActive()
            },
        ]
    }

    deinit {
        for observer in observers { NotificationCenter.default.removeObserver(observer) }
        if let engineObserver { NotificationCenter.default.removeObserver(engineObserver) }
    }

    func start() throws {
        var thrown: Error?
        queue.sync {
            wantsRunning = true
            do {
                try configureSession()
                try startEngine()
                startWatchdog()
            } catch {
                // A start that fails leaves nothing running and nothing retrying: the caller says why.
                thrown = error
                wantsRunning = false
                stopWatchdog()
                teardownEngine()
                try? session.setActive(false, options: .notifyOthersOnDeactivation)
            }
        }
        if let thrown {
            handlers.state(.error, thrown.localizedDescription)
            throw thrown
        }
    }

    func stop() {
        queue.sync {
            wantsRunning = false
            recovery.cancel()
            stopWatchdog()
            teardownEngine()
            try? session.setActive(false, options: .notifyOthersOnDeactivation)
        }
        handlers.state(.stopped, nil)
    }

    // MARK: Session and engine

    /// The same category, mode and options every time, so a restart after a call matches the first start.
    /// `mixWithOthers` keeps music playing; the `audio` background mode keeps it recording with the screen locked.
    /// The iPhone's own mic, never a Bluetooth one: opening AirPods' mic drops them to call quality (HFP) for the
    /// whole recording, music included (the Mac app never opens one by accident either). A2DP keeps their playback.
    private func configureSession() throws {
        try session.setCategory(.playAndRecord, mode: .default, options: [.mixWithOthers, .allowBluetoothA2DP, .defaultToSpeaker])
        try session.setPreferredIOBufferDuration(0.02)
        try session.setActive(true)
    }

    private func startEngine() throws {
        teardownEngine()
        let engine = AVAudioEngine()
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else { throw MicError.noInput }
        guard let maker = FrameMaker(from: format, onFrame: handlers.frame) else { throw MicError.cantConvert }

        // About 100 ms of input per callback, on the tap's own thread. Each one tells the watchdog audio still comes.
        let lastFrame = self.lastFrame
        input.installTap(onBus: 0, bufferSize: AVAudioFrameCount(format.sampleRate / 10), format: format) { buffer, when in
            lastFrame.withLock { $0 = FrameMaker.monotonicNow() }
            maker.process(buffer, at: when)
        }
        engineObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange, object: engine, queue: nil
        ) { [weak self] _ in
            self?.restartIfWanted(after: 0.2)
        }
        self.engine = engine
        engine.prepare()
        do {
            try engine.start()
        } catch {
            teardownEngine()
            throw error
        }
        builtFor = MicInput(session)
        // A fresh engine: its first buffer is a few ms away, so the silence is counted from now.
        lastFrame.withLock { $0 = FrameMaker.monotonicNow() }
        hearing = true
        handlers.state(.running, nil)
    }

    // MARK: Watchdog

    /// A tap that stops delivering with no notification at all (seen on devices after a call or a route change, the
    /// engine still saying it runs) would record nothing while every screen says recording. Every few seconds this
    /// checks a buffer came lately; if not, it says paused and rebuilds the engine, once per stall.
    private func startWatchdog() {
        stopWatchdog()
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + MicWatchdog.interval, repeating: MicWatchdog.interval, leeway: .seconds(1))
        timer.setEventHandler { [weak self] in self?.checkFrames() }
        timer.resume()
        watchdog = timer
    }

    private func stopWatchdog() {
        watchdog?.cancel()
        watchdog = nil
    }

    private func checkFrames() {
        let age = FrameMaker.monotonicNow() - lastFrame.withLock { $0 }
        guard wantsRunning, MicWatchdog.stalled(age: age, hearing: hearing) else { return }
        // Not hearing until a rebuild works: the restart's own misses back off as usual and this doesn't fire again
        // (or reset that backoff) meanwhile.
        hearing = false
        Log.note("mic: no audio for \(Int(MicWatchdog.stallSeconds)) s, rebuilding")
        handlers.state(.interrupted, "No sound from the mic")
        recovery.restart()
    }

    private func teardownEngine() {
        hearing = false
        if let engineObserver { NotificationCenter.default.removeObserver(engineObserver) }
        engineObserver = nil
        guard let engine else { return }
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        self.engine = nil
    }

    /// Try to get going again. If the mic is still busy (a call ringing, or iOS refusing to reactivate from the
    /// background), RecoveryLoop retries with growing delays and, after a few misses, says it needs the app opened.
    private func restartIfWanted(after delay: TimeInterval) {
        queue.async { [weak self] in
            guard let self, self.wantsRunning else { return }
            self.recovery.restart(after: delay)
        }
    }

    // MARK: System events (any thread)

    private func interrupted(_ type: AVAudioSession.InterruptionType?) {
        switch type {
        case .began:
            queue.async { [weak self] in
                guard let self, self.wantsRunning else { return }
                self.hearing = false  // no frames now is the interruption, not a stall
                self.handlers.state(.interrupted, "Paused by another app")
            }
        case .ended:
            // Resume even if the system didn't say to: a recording runs until it's stopped.
            restartIfWanted(after: 0.3)
        default:
            break
        }
    }

    /// Any route change: the engine is built again only if the input changed (another port, another format) or the
    /// engine stopped. Rebuilding it for every change dropped audio and flashed "Paused" each time AirPods connected
    /// for music, though the input stays the iPhone's mic.
    private func routeChanged() {
        queue.async { [weak self] in
            guard let self, self.wantsRunning else { return }
            let now = MicInput(self.session)
            guard MicInput.needsRestart(builtFor: self.builtFor, now: now, engineRunning: self.engine?.isRunning == true)
            else { return }
            self.recovery.restart(after: 0.2)
        }
    }

    private func mediaServicesReset() {
        queue.async { [weak self] in
            guard let self else { return }
            // The old engine died with the media services: drop it without touching it.
            if let observer = self.engineObserver { NotificationCenter.default.removeObserver(observer) }
            self.engineObserver = nil
            self.engine = nil
            self.hearing = false
            if self.wantsRunning { self.recovery.restart(after: 0.5) }
        }
    }

    /// iOS doesn't always say an interruption ended (after some calls). Opening the app fixes it, and it's the one
    /// moment iOS reliably lets the session come back. Not only when the engine says it stopped: one that says it
    /// runs but delivers nothing is rebuilt too.
    private func becameActive() {
        queue.async { [weak self] in
            guard let self, self.wantsRunning else { return }
            let age = FrameMaker.monotonicNow() - self.lastFrame.withLock { $0 }
            guard MicWatchdog.restartOnActive(hearing: self.hearing, engineRunning: self.engine?.isRunning == true, age: age)
            else { return }
            self.recovery.restart()
        }
    }
}

/// When the mic counts as stalled: plain values, so the decisions are unit tested (SonaTests/V1RecordingTests.swift).
nonisolated enum MicWatchdog {
    /// How often it checks.
    static let interval: TimeInterval = 5
    /// No buffer for this long while hearing is a stall (buffers come every 100 ms).
    static let stallSeconds: TimeInterval = 5

    /// `age`: seconds since the last buffer. Only while hearing: during an interruption or a restart's backoff no audio
    /// is expected, and firing then would reset the backoff that leads to "Open Sona".
    static func stalled(age: TimeInterval, hearing: Bool) -> Bool {
        hearing && age > stallSeconds
    }

    /// Back on screen: rebuild if it isn't hearing, the engine stopped, or it says it runs but nothing came lately.
    static func restartOnActive(hearing: Bool, engineRunning: Bool, age: TimeInterval) -> Bool {
        !hearing || !engineRunning || age > stallSeconds
    }
}

/// The mic input as far as a route change can touch it: which port, and the format the engine gets from it. Plain
/// values, so the restart decision is unit tested (SonaTests/MicRouteTests.swift).
nonisolated struct MicInput: Equatable, Sendable {
    /// The input port's uid; nil when there's no input (a call can take it).
    var port: String?
    var sampleRate: Double
    var channels: Int

    /// After a route change the engine is built again only if the input changed under it, or it stopped (it does
    /// when the hardware format changes, and says so with a configuration change too). Unknown means restart.
    static func needsRestart(builtFor: MicInput?, now: MicInput, engineRunning: Bool) -> Bool {
        guard engineRunning, let builtFor else { return true }
        return builtFor != now
    }
}

extension MicInput {
    /// What the session says now. Read on the mic's queue, like everything else that touches the session.
    nonisolated init(_ session: AVAudioSession) {
        self.init(
            port: session.currentRoute.inputs.first?.uid, sampleRate: session.sampleRate,
            channels: session.inputNumberOfChannels)
    }
}

nonisolated enum MicError: LocalizedError, LogSafeError {
    case noInput
    case cantConvert

    var errorDescription: String? {
        switch self {
        case .noInput: "No microphone is available."
        case .cantConvert: "The microphone's audio couldn't be converted."
        }
    }
}
