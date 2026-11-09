import Foundation
import LiveCore
import NotesKit

/// The app's one mic. Opens, closes and reopens it on one serial queue (never the main thread: Core Audio can
/// block for seconds right after a wake), as `MicHealth` decides, and passes its audio to the live session's
/// relay and, while always-on recording is on, to the recorder. `LIVE_FILE` test runs play a file (then a quiet
/// room) instead of the mic.
// @unchecked: `health`, `source`, `timer`, `generation`, `preferredUID`, `published` and `watch` are only touched
// on `queue`; what the audio thread reads (the consumers, the generation passed on, the last audio time) and the
// pace (with the open source it's passed to) are under `lock`.
final class MicDriver: @unchecked Sendable {
    private let queue = DispatchQueue(label: "sona.mic", qos: .userInitiated)
    private var health = MicHealth()
    private var source: LiveAudioSource?
    private var timer: DispatchSourceTimer?
    private var generation = 0
    private var preferredUID: String?
    private var published = MicHealth.State.off
    private var watch: InputDevices.Watch?
    private let file: URL?
    /// The host time the test file counts as starting from, read when it first opens (`TestRun.clockStart`).
    private var fileStart: (@Sendable () -> Double)?
    private let onState: @Sendable (MicHealth.State) -> Void

    private let lock = NSLock()
    private var passing = 0
    private var lastAudio = -Double.infinity
    private var relay: RelaySource?
    private var recorder: AudioBatcher?
    /// The open source, and whether the live session wants its audio every 10 ms (else in ~50 ms batches: the
    /// recorder alone never minds).
    private var current: LiveAudioSource?
    private var urgent = false

    /// `onState` is called on the main thread whenever the state changes.
    init(
        file: URL?, startHost: (@Sendable () -> Double)? = nil, preferredUID: String?,
        onState: @escaping @Sendable (MicHealth.State) -> Void
    ) {
        self.file = file
        fileStart = startHost
        self.preferredUID = preferredUID
        self.onState = onState
        guard file == nil else { return }
        queue.async { [self] in
            watch = InputDevices.watch(queue: queue) { [weak self] in self?.devicesChanged() }
        }
    }

    /// Loudness of the latest audio, dBFS (for the level dot): the mic works it out once per piece it hands over.
    var level: Float { lock.withLock { (current as? MicSource)?.level } ?? -90 }

    /// The live session's relay: the mic hands audio over as often as its session asks.
    func setRelay(_ relay: RelaySource?) {
        let old = lock.withLock { () -> RelaySource? in
            defer { self.relay = relay }
            return self.relay
        }
        old?.paced(by: nil)
        guard let relay else { return setUrgent(false, from: nil) }
        relay.paced(by: { [weak self, weak relay] on in self?.setUrgent(on, from: relay) })
    }

    func setRecorder(_ recorder: AudioBatcher?) { lock.withLock { self.recorder = recorder } }

    /// Any thread. Only the current relay's session sets the pace.
    private func setUrgent(_ on: Bool, from relay: RelaySource?) {
        lock.withLock {
            guard relay === self.relay else { return }
            urgent = on
            current?.setUrgent(on)
        }
    }

    func setWanted(_ on: Bool) {
        queue.async { [self] in
            run(health.setWanted(on, now: hostNow()))
            keepTicking()
        }
    }

    /// The microphone setting changed.
    func setPreferred(_ uid: String?) {
        queue.async { [self] in
            guard uid != preferredUID else { return }
            preferredUID = uid
            health.devicesChanged(now: hostNow())
            tickWhenDue()
        }
    }

    func woke() {
        guard file == nil else { return }
        queue.async { [self] in
            health.woke(now: hostNow())
            tickWhenDue()
        }
    }

    // MARK: on `queue`

    /// Devices came or went: reopen if a different one should be recording, or if none was open.
    private func devicesChanged() {
        guard health.wanted else { return }
        let want = InputDevices.pick(preferredUID: preferredUID)?.uid
        let have = (source as? MicSource)?.device?.uid
        guard want != have || source == nil else { return }
        health.devicesChanged(now: hostNow())
        tickWhenDue()
    }

    /// Once a second while wanted (for the silence check), nothing at all otherwise. Reopens that are due sooner
    /// (a device change settles in 0.5 s) get a tick of their own.
    private func keepTicking() {
        if health.wanted, timer == nil {
            let t = DispatchSource.makeTimerSource(queue: queue)
            t.schedule(deadline: .now() + 1, repeating: 1, leeway: .milliseconds(200))
            t.setEventHandler { [weak self] in self?.tick() }
            t.resume()
            timer = t
        } else if !health.wanted, let t = timer {
            t.cancel()
            timer = nil
        }
    }

    /// A tick right when the next (re)open is due, or `after` seconds from now.
    private func tickWhenDue(after: Double? = nil) {
        guard let wait = after ?? health.openAt.map({ max($0 - hostNow(), 0) }) else { return }
        queue.asyncAfter(deadline: .now() + wait + 0.01) { [weak self] in self?.tick() }
    }

    private func tick() {
        health.heard(at: lock.withLock { lastAudio })
        run(health.tick(now: hostNow()))
    }

    private func run(_ actions: [MicHealth.Action]) {
        for action in actions {
            switch action {
            case .open: open()
            case .close: close()
            }
        }
        let state = health.state
        guard state != published else { return }
        published = state
        let onState = onState
        DispatchQueue.main.async { onState(state) }
    }

    private func open() {
        close()
        generation += 1
        let gen = generation
        lock.withLock { passing = gen }
        let tap: AudioTap = { [weak self] samples, host in self?.deliver(samples, host, gen) }
        do {
            let opened: LiveAudioSource
            if let file {
                let f = try FileSource(url: file, thenSilence: true, startHost: fileStart?())
                fileStart = nil
                f.tap = tap
                opened = f
            } else {
                let m = MicSource(preferredUID: preferredUID)
                m.tap = tap
                m.onChange = { [weak self] in
                    guard let self else { return }
                    self.queue.async {
                        self.health.devicesChanged(now: hostNow())
                        self.tickWhenDue()
                    }
                }
                opened = m
            }
            // At the session's pace from its first sample (set under the lock, so a change can't slip in between).
            lock.withLock {
                current = opened
                opened.setUrgent(urgent)
            }
            try opened.start()
            source = opened
            health.opened(now: hostNow())
            // Its kind, not its name (often the owner's).
            let name = (opened as? MicSource)?.device.map { "\($0.label) mic" } ?? file.map { "the file \($0.lastPathComponent)" } ?? "?"
            Log.note("mic opened: \(name)")
            // Say "running" as soon as its first audio is in, not at the next once-a-second tick.
            tickWhenDue(after: 0.25)
        } catch {
            lock.withLock { current = nil }
            let why = Self.describe(error)
            health.openFailed(why, now: hostNow())
            // By code: what the window shows can name the mic ("Couldn't open Someone's AirPods").
            Log.note("mic didn't open: \(Log.describe(error))")
            tickWhenDue()
        }
    }

    private func close() {
        guard let s = source else { return }
        source = nil
        lock.withLock {
            passing = 0
            current = nil
        }
        s.stop()
        Log.note("mic closed")
    }

    // MARK: audio thread

    private func deliver(_ samples: [Float], _ host: Double, _ gen: Int) {
        let (relay, recorder) = lock.withLock { () -> (RelaySource?, AudioBatcher?) in
            guard gen == passing else { return (nil, nil) }  // the last moments of a mic that was just replaced
            lastAudio = host + Double(samples.count) / AudioClock.sampleRate
            return (self.relay, self.recorder)
        }
        relay?.push(samples, hostTime: host)
        recorder?.push(samples, hostTime: host)
    }

    /// A plain reason for the menu.
    static func describe(_ error: Error) -> String {
        let ns = error as NSError
        if ns.domain == "SonaLive", ns.code == 1 { return "No microphone found" }
        if ns.domain == "SonaLive", ns.code == 2 { return ns.localizedDescription }
        return "The microphone didn't start (\(ns.localizedDescription))"
    }
}
