import CoreAudio
import Foundation
import LiveCore
import NotesKit

/// The app's one ear on what this Mac plays. Opens and closes the Core Audio tap on one serial queue as
/// `MacAudio.Lifecycle` decides (something playing, the switch on, listening, not paused or asleep), and passes its
/// audio to the Mac track's live session and the recorder, like `MicDriver` does for the mic. With nothing playing
/// there's no tap at all: only Core Audio's listeners, which cost nothing until something changes. A tap whose audio
/// stops coming while apps play (its output went away under it) is opened again. Apps that only hold an output open
/// don't keep it running on silence: `MacAudio.Quiet` closes it, though the Mac's track stays on, and opens it again
/// when there may be something to hear.
///
/// `LIVE_FILE_MAC` test runs play that file instead (no tap, no listeners: never anyone's real apps), starting at the
/// same moment as `LIVE_FILE`'s.
// @unchecked: everything but the consumers and the last-audio time is only touched on `queue`; those (read on the
// audio side) are under `lock`.
final class MacAudioDriver: @unchecked Sendable {
    enum State: Equatable {
        case off
        /// The tap (or test file) is running.
        case on
        /// Something's wrong, in plain words (no permission, the tap didn't start).
        case problem(String)
    }

    private let queue = DispatchQueue(label: "mac-audio.driver", qos: .userInitiated)
    private let file: URL?
    private let onState: @Sendable (State) -> Void
    private var want = MacAudio.Want(supported: MacAudio.supported)
    private var lifecycle = MacAudio.Lifecycle()
    private var source: LiveAudioSource?
    private var watch: MacAudio.Watch?
    private var timer: DispatchSourceTimer?
    private var openedAt = 0.0
    private var failures = 0
    private var retryAt = 0.0
    private var published = State.off
    private var generation = 0
    /// The test file has played to its end (it isn't played again).
    private var fileDone = false
    /// The apps playing at the last look (nil: none since watching began).
    private var players: Set<AudioObjectID>?
    /// When an app last started playing while watched.
    private var lastStart = -Double.infinity
    private var quiet = MacAudio.Quiet(now: 0)
    /// A tap has heard sound since launch: the permission is there.
    private var everHeard = false

    private let lock = NSLock()
    private var passing = 0
    private var relay: RelaySource?
    private var recorder: AudioBatcher?
    private var lastAudio = -Double.infinity
    /// The end of the last audio that wasn't silence.
    private var lastSound = -Double.infinity
    /// Quieter than this (-80 dBFS) is silence: what an app holding an open output plays.
    static let silence: Float = 1e-4

    /// `onState` is called on the main thread whenever the state changes.
    init(file: URL?, onState: @escaping @Sendable (State) -> Void) {
        self.file = file
        self.onState = onState
        if file != nil { want.supported = true }
    }

    func setRelay(_ relay: RelaySource?) { lock.withLock { self.relay = relay } }
    func setRecorder(_ recorder: AudioBatcher?) { lock.withLock { self.recorder = recorder } }

    /// The switch, and whether the app is listening (always-on, begun, not paused, awake).
    func update(switchOn: Bool, listening: Bool, paused: Bool, asleep: Bool) {
        queue.async { [self] in
            want.switchOn = switchOn
            want.listening = listening
            want.paused = paused
            want.asleep = asleep
            let wanted = switchOn && listening && !paused && !asleep
            if file == nil {
                if wanted, watch == nil {
                    watch = MacAudio.Watch(queue: queue) { [weak self] in self?.evaluate() }
                } else if !wanted, let w = watch {
                    w.stop()
                    watch = nil
                }
            }
            evaluate()
        }
    }

    // MARK: on `queue`

    private func evaluate() {
        let now = hostNow()
        if file != nil {
            want.playing = !fileDone
        } else {
            let watched = want.switchOn && want.listening
            let playing = watched ? MacAudio.players() : []
            if let before = players, !playing.isSubset(of: before) { lastStart = now }
            players = watched ? playing : nil
            want.playing = !playing.isEmpty
        }
        if let action = lifecycle.update(want, now: now) {
            switch action {
            case .open: open(now: now)
            case .close: close(why: want.playing ? "not listening" : "nothing playing")
            }
        }
        hush(now: now)
        keepTicking()
    }

    /// After a long silence, closes the tap but stays on; opens it again for an app that starts playing, or for a
    /// short look now and then (those aren't logged).
    private func hush(now: Double) {
        guard file == nil, lifecycle.open, retryAt == 0 else { return }
        let peek = quiet.peeking
        switch quiet.update(playing: players ?? [], lastSound: lock.withLock { lastSound }, now: now) {
        case .close?:
            if !peek { Log.note("Mac audio tap closed: silence for \(Int(MacAudio.Quiet.closeAfter)) s (still on)") }
            stopTap()
        case .open?:
            open(now: now, note: quiet.peeking ? nil : "Mac audio tap opened again (an app started playing)", peek: quiet.peeking)
        case nil:
            break
        }
    }

    /// Once a second while the tap runs or a change is due; nothing otherwise.
    private func keepTicking() {
        let needed = lifecycle.open || lifecycle.next(now: hostNow()) != nil || retryAt > 0
        if needed, timer == nil {
            let t = DispatchSource.makeTimerSource(queue: queue)
            t.schedule(deadline: .now() + 1, repeating: 1, leeway: .milliseconds(250))
            t.setEventHandler { [weak self] in self?.tick() }
            t.resume()
            timer = t
        } else if !needed, let t = timer {
            t.cancel()
            timer = nil
        }
    }

    private var ticks = 0
    /// No audio for this long from a tap that had been sending it, while apps play: it's stuck.
    static let stallAfter = 2.0

    private func tick() {
        let now = hostNow()
        ticks += 1
        if lifecycle.open, source == nil, retryAt > 0, now >= retryAt { open(now: now) }
        if lifecycle.open, let opened = source {
            let sinceAudio = now - lock.withLock { lastAudio }
            if file != nil, now - openedAt > 3, sinceAudio > 3 {
                // The test file played to its end: like the Mac going quiet.
                fileDone = true
            } else if file == nil, want.playing, sinceAudio > Self.stallAfter, now - openedAt > 3, blocks(opened) > 0 {
                open(now: now, note: "Mac audio tap opened again (its audio stopped)")
            }
            if let source { check(source, now: now) }
        }
        hush(now: now)
        // While it runs, look again every 3 s whether anything still plays (a few ms each time).
        if file != nil || ticks % 3 == 0 || lifecycle.next(now: now) != nil { evaluate() } else { keepTicking() }
    }

    /// IO blocks the tap has had (0 for a test file).
    private func blocks(_ source: LiveAudioSource) -> Int {
        guard #available(macOS 14.2, *), let tap = source as? MacAudioTap else { return 0 }
        return tap.blocks
    }

    /// A running tap that gets no audio at all, or only exact silence while apps play, likely has no permission.
    private func check(_ source: LiveAudioSource, now: Double) {
        guard file == nil, #available(macOS 14.2, *), let tap = source as? MacAudioTap, now - openedAt > 3 else { return }
        if tap.heardSound { everHeard = true }
        let state: State
        if tap.blocks == 0 {
            state = .problem("No Mac audio is coming through. Allow it in System Settings, Privacy & Security, Screen & System Audio Recording, then quit and reopen.")
        } else if !everHeard, lastStart >= openedAt - 2, now - max(lastStart, openedAt) > 20 {
            // Only zeros since an app started playing. Apps that only hold an output open play zeros too, so
            // silence from those (already playing when it opened), or after any sound since launch, doesn't count.
            state = .problem("Only silence from this Mac's audio. If something is playing, allow it in System Settings, Privacy & Security, Screen & System Audio Recording.")
        } else {
            state = .on
        }
        publish(state)
    }

    /// `note`: what to log once it's open (nil: "Mac audio on"). A `peek` logs nothing and leaves the state as it is.
    private func open(now: Double, note: String? = nil, peek: Bool = false) {
        close(why: nil)
        generation += 1
        let gen = generation
        lock.withLock {
            passing = gen
            lastAudio = now
        }
        let tap: AudioTap = { [weak self] samples, host in self?.deliver(samples, host, gen) }
        do {
            let opened: LiveAudioSource
            if let file {
                let f = try FileSource(url: file, thenSilence: false, startHost: TestRun.clockStart)
                f.tap = tap
                opened = f
            } else if #available(macOS 14.2, *) {
                let t = MacAudioTap()
                t.tap = tap
                t.logs = !peek
                opened = t
            } else {
                return
            }
            try opened.start()
            source = opened
            openedAt = now
            failures = 0
            retryAt = 0
            guard !peek else { return }
            // Counting silence from now.
            quiet = MacAudio.Quiet(now: now)
            publish(.on)
            Log.note(note ?? "Mac audio on" + (file.map { ": the file \($0.lastPathComponent)" } ?? ""))
        } catch {
            // Try again in 30 s, 60 s ... (10 min at most) while it's still wanted.
            failures += 1
            retryAt = now + min(30 * pow(2, Double(failures - 1)), 600)
            Log.note("Mac audio didn't start: \(Log.describe(error))")
            publish(.problem("This Mac's audio couldn't be heard (\(error.localizedDescription)). Trying again."))
        }
    }

    private func close(why: String?) {
        retryAt = 0
        let wasOn = source != nil || quiet.closed
        stopTap()
        guard let why else { return }
        if wasOn { Log.note("Mac audio off (\(why))") }
        publish(.off)
    }

    /// Stops the tap; the state stays as it is.
    private func stopTap() {
        guard let s = source else { return }
        source = nil
        lock.withLock { passing = 0 }
        s.stop()
    }

    private func publish(_ state: State) {
        guard state != published else { return }
        published = state
        let onState = onState
        DispatchQueue.main.async { onState(state) }
    }

    // MARK: audio side

    private func deliver(_ samples: [Float], _ host: Double, _ gen: Int) {
        let sound = samples.contains { abs($0) > Self.silence }
        let (relay, recorder) = lock.withLock { () -> (RelaySource?, AudioBatcher?) in
            guard gen == passing else { return (nil, nil) }
            lastAudio = host + Double(samples.count) / AudioClock.sampleRate
            if sound { lastSound = lastAudio }
            return (self.relay, self.recorder)
        }
        relay?.push(samples, hostTime: host)
        recorder?.push(samples, hostTime: host)
    }
}
