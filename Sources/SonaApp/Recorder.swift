import Foundation
import LiveCore
import NotesKit
import SonaEngine

/// Always-on listening: the mic's audio → Listener (voice detection, a new conversation after 3 minutes of
/// quiet, the crash-safe spool). Only exists while always-on recording is on. Finished conversations go to the
/// app's one Processor (Parakeet TDT and the offline diarizer → a note), which outlives it.
@MainActor
final class Recorder {
    /// Where the mic sends its audio (any thread).
    let input: AudioBatcher
    /// Where this Mac's audio goes (any thread), lined up with the mic's by capture time in the pump.
    let macInput: AudioBatcher
    private let pump: Pump

    private init(pump: Pump) {
        self.pump = pump
        input = AudioBatcher { samples, date in pump.send(.frame(samples, date)) }
        macInput = AudioBatcher { samples, date in pump.send(.mac(samples, date)) }
    }

    /// Loads the voice detector and starts taking audio. `onEvent` is called on the main thread.
    static func make(
        settings: Settings, spool: Spool, onEvent: @escaping @Sendable @MainActor (Listener.Event) -> Void
    ) async throws -> Recorder {
        let vad = try await Models.loadVAD(threshold: 0.6)
        let listener = await Listener(vad: vad, spool: spool, config: Listener.Config(quietSeconds: settings.quietMinutes * 60))
        // Only runs while a conversation is open; never in test runs (it would hear this Mac's real speakers).
        if TestRun.file == nil { listener.playbackProbe = Playback.sample }
        let pump = Pump(ListenerBox(listener))
        pump.start { event in
            DispatchQueue.main.async { MainActor.assumeIsolated { onEvent(event) } }
        }
        return Recorder(pump: pump)
    }

    /// Pause, or the Mac going to sleep: the open conversation ends here.
    func close(_ reason: String) {
        input.flush()
        macInput.flush()
        pump.send(.close(reason))
    }

    /// After a pause or a wake: forget the room's recent state and the time continuity.
    func reset() { pump.send(.reset) }

    /// "Delete the last N minutes": the open conversation keeps nothing from `cut` on (it's closed there, or dropped
    /// if it started after), and audio still queued from before now is dropped. Returns once that's done.
    func forget(from cut: Date) async {
        input.flush()
        macInput.flush()
        pump.send(.forget(cut))
        await pump.idle()
    }

    /// Always-on turned off, or quitting: the open conversation goes to the spool as closed (its `.closed` event
    /// reaches the main thread before this returns), then the loop ends.
    func finish(reason: String) async {
        input.flush()
        macInput.flush()
        pump.send(.close(reason))
        await pump.idle()
        pump.end()
    }
}

/// Owns the Listener on one serial loop, so frames, closes and resets never interleave (an actor would let them,
/// at every await inside the VAD call).
final class Pump: Sendable {
    enum Command: Sendable {
        case frame([Float], Date)
        /// This Mac's audio, captured at that time.
        case mac([Float], Date)
        case close(String)
        case reset
        case forget(Date)
        case idle(CheckedContinuation<Void, Never>)
    }

    private let box: ListenerBox
    private let stream: AsyncStream<Command>
    private let continuation: AsyncStream<Command>.Continuation

    init(_ box: ListenerBox) {
        self.box = box
        (stream, continuation) = AsyncStream.makeStream(of: Command.self)
    }

    func start(onEvent: @escaping @Sendable (Listener.Event) -> Void) {
        box.listener.onEvent = onEvent
        let box = box, stream = stream
        Task.detached(priority: .userInitiated) {
            let listener = box.listener
            // Audio captured before a pause or sleep, still queued, mustn't open a new conversation after it.
            var dropBefore = Date.distantPast
            // The Mac's audio, lined up with the mic's. With nothing playing a mic frame goes straight through.
            var aligner = TrackAligner()
            func feed(_ frames: [TrackAligner.Frame]) async throws {
                for f in frames where f.at >= dropBefore { try await listener.feed(f.mic, mac: f.mac, at: f.at) }
            }
            for await command in stream {
                do {
                    switch command {
                    case .frame(let samples, let at):
                        guard at >= dropBefore else { continue }
                        aligner.addMic(samples, at: at)
                        try await feed(aligner.ready(now: Date()))
                    case .mac(let samples, let at):
                        guard at >= dropBefore else { continue }
                        aligner.addMac(samples, at: at, now: Date())
                        try await feed(aligner.ready(now: Date()))
                    case .close(let reason):
                        try await feed(aligner.flush(now: Date()))
                        try listener.close(reason: reason)
                        dropBefore = Date()
                    case .reset:
                        _ = aligner.flush(now: Date())
                        aligner.reset()
                        await listener.reset()
                        dropBefore = Date()
                    case .forget(let cut):
                        dropBefore = Date()
                        _ = aligner.flush(now: Date())
                        aligner.reset()
                        try await listener.forget(from: cut)
                    case .idle(let done):
                        done.resume()
                    }
                } catch {
                    Log.note("listener error: \(Log.describe(error))")
                }
            }
            // Ended: nothing keeps the listener, its events or the spool file alive any more.
            listener.onEvent = { _ in }
        }
    }

    func send(_ command: Command) { continuation.yield(command) }

    /// Waits until everything sent so far has run.
    func idle() async { await withCheckedContinuation { send(.idle($0)) } }

    func end() { continuation.finish() }
}

/// The Listener isn't thread-safe; only the pump's loop touches it after `start`.
final class ListenerBox: @unchecked Sendable {
    let listener: Listener
    init(_ listener: Listener) { self.listener = listener }
}

/// Groups the mic's 10 ms pieces into 100 ms frames for the Listener, each with the wall-clock time of its first
/// sample (from the capture host time). A piece that doesn't follow on from the last (a reopened mic) starts a new
/// frame, so the Listener sees the gap and keeps every timestamp true.
// @unchecked: everything is under `lock`.
final class AudioBatcher: @unchecked Sendable {
    private let lock = NSLock()
    private var samples: [Float] = []
    private var firstHost = 0.0
    private let frame = 1_600
    private let send: @Sendable ([Float], Date) -> Void

    init(send: @escaping @Sendable ([Float], Date) -> Void) { self.send = send }

    func push(_ piece: [Float], hostTime: Double) {
        lock.withLock {
            if !samples.isEmpty, abs(hostTime - (firstHost + Double(samples.count) / AudioClock.sampleRate)) > 0.05 {
                flushLocked()
            }
            if samples.isEmpty {
                firstHost = hostTime
                samples.reserveCapacity(frame + 480)
            }
            samples.append(contentsOf: piece)
            if samples.count >= frame { flushLocked() }
        }
    }

    func flush() { lock.withLock { flushLocked() } }

    private func flushLocked() {
        guard !samples.isEmpty else { return }
        send(samples, Date(timeIntervalSinceNow: firstHost - hostNow()))
        samples = []
    }
}
