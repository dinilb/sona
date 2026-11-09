import AVFoundation
import CoreAudio
import Foundation
import NotesKit

/// Hearing what this Mac plays (a video, a call, music) as its own track, through a Core Audio process tap.
/// Read Apple's "Capturing system audio with Core Audio taps" first; AudioCap (BSD-2) and hearsay (MIT) were
/// read for how others set the tap up (see THIRD_PARTY.md).
public enum MacAudio {
    /// What decides whether the tap runs.
    public struct Want: Sendable, Equatable {
        /// The "hear this Mac's audio too" switch.
        public var switchOn = false
        /// Always-on recording is on and listening has begun (first run done, the mic allowed).
        public var listening = false
        public var paused = false
        public var asleep = false
        /// Some app other than this one is playing to an output right now.
        public var playing = false
        /// macOS 14.2 or later (process taps).
        public var supported = false

        public init(
            switchOn: Bool = false, listening: Bool = false, paused: Bool = false, asleep: Bool = false,
            playing: Bool = false, supported: Bool = false
        ) {
            self.switchOn = switchOn
            self.listening = listening
            self.paused = paused
            self.asleep = asleep
            self.playing = playing
            self.supported = supported
        }
    }

    /// Tap only while it's wanted and something is playing: with nothing playing there's no tap and no work.
    public static func shouldTap(_ w: Want) -> Bool {
        w.switchOn && w.listening && !w.paused && !w.asleep && w.playing && w.supported
    }

    /// When to open and close the tap, from `shouldTap` over time: open once it has been wanted for `openAfter`
    /// (a click or a notification sound is over by then), close once it hasn't been for `closeAfter` (a paused
    /// video doesn't churn it), at once when it's not wanted for any other reason than nothing playing. Pure.
    public struct Lifecycle: Sendable, Equatable {
        public enum Action: Sendable, Equatable { case open, close }
        public static let openAfter = 0.5
        public static let closeAfter = 15.0

        public private(set) var open = false
        private var since: Double?

        public init() {}

        /// The state at `now`; returns what to do. Call again after `next` seconds while one is pending.
        public mutating func update(_ want: Want, now: Double) -> Action? {
            let wanted = MacAudio.shouldTap(want)
            if wanted == open {
                since = nil
                return nil
            }
            // Turned off, paused or asleep: close now. Only "nothing playing" waits.
            if open, !(want.switchOn && want.listening && !want.paused && !want.asleep && want.supported) {
                open = false
                since = nil
                return .close
            }
            let started = since ?? now
            since = started
            guard now - started >= (wanted ? Self.openAfter : Self.closeAfter) else { return nil }
            open = wanted
            since = nil
            return wanted ? .open : .close
        }

        /// Seconds until a pending change is due, if one is.
        public func next(now: Double) -> Double? {
            since.map { max(0, $0 + (open ? Self.closeAfter : Self.openAfter) - now) }
        }
    }

    /// Apps that hold an output open while playing nothing (a call app between calls, a browser after a video)
    /// count as playing, so the tap would run on silence for hours. After `closeAfter` of silence the tap closes,
    /// though the Mac's track stays on, and those apps alone don't open it again: another app starting to play does,
    /// one of them stopping and starting again does, and so does a `peekFor` look every `peekEvery` (one of them can
    /// start making sound without Core Audio saying so: someone talks on a call). Pure.
    public struct Quiet: Sendable, Equatable {
        public enum Action: Sendable, Equatable { case close, open }
        public static let closeAfter = 45.0
        public static let peekEvery = 15.0
        public static let peekFor = 1.0

        /// Closed for silence.
        public private(set) var closed = false
        /// Open for a look, not because an app started playing.
        public private(set) var peeking = false
        /// The apps that were playing when it closed (their process objects).
        public private(set) var holders: Set<AudioObjectID> = []
        /// When it last opened or closed.
        private var since: Double

        /// The tap opened at `now`.
        public init(now: Double) { since = now }

        /// `playing`: the apps playing to an output now. `lastSound`: when the tap last heard anything but silence.
        public mutating func update(playing: Set<AudioObjectID>, lastSound: Double, now: Double) -> Action? {
            if closed {
                // One that stopped is new again when it starts.
                holders.formIntersection(playing)
                let someoneNew = !playing.isSubset(of: holders)
                guard someoneNew || (!playing.isEmpty && now - since >= Self.peekEvery) else { return nil }
                closed = false
                peeking = !someoneNew
                since = now
                return .open
            }
            // It heard something: an ordinary run.
            if lastSound >= since { peeking = false }
            guard now - max(lastSound, since) >= (peeking ? Self.peekFor : Self.closeAfter) else { return nil }
            closed = true
            peeking = false
            holders = playing
            since = now
            return .close
        }
    }

    /// Process taps exist (macOS 14.2+).
    public static var supported: Bool {
        if #available(macOS 14.2, *) { return true }
        return false
    }

    /// The apps other than this one playing to an output right now (their process objects). Reads the process
    /// list (a few ms): only on an audio event, and every few seconds while the tap runs.
    public static func players() -> Set<AudioObjectID> {
        let me = getpid()
        return Set(
            CA.array(CA.system, kAudioHardwarePropertyProcessObjectList).filter { process in
                CA.get(process, kAudioProcessPropertyIsRunningOutput, default: UInt32(0)) != 0
                    && CA.get(process, kAudioProcessPropertyPID, default: pid_t(-1)) != me
            })
    }

    /// Calls `handler` on `queue` when audio may have started or stopped playing: the default output changed, an
    /// app's audio came or went, an app started or stopped playing, or the default output started or stopped
    /// running. Nothing is polled.
    public final class Watch: @unchecked Sendable {
        // @unchecked: `device` and `processes` are only touched on `queue`, where every listener runs.
        private let queue: DispatchQueue
        private let handler: @Sendable () -> Void
        private var device = AudioObjectID(kAudioObjectUnknown)
        private var processes: Set<AudioObjectID> = []
        private var system: AudioObjectPropertyListenerBlock?
        private var running: AudioObjectPropertyListenerBlock?
        private var output: AudioObjectPropertyListenerBlock?

        public init(queue: DispatchQueue, _ handler: @escaping @Sendable () -> Void) {
            self.queue = queue
            self.handler = handler
            queue.async { self.listen() }
        }

        private func listen() {
            let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
                self?.follow()
                self?.handler()
            }
            system = block
            output = { [weak self] _, _ in self?.handler() }
            for selector in [kAudioHardwarePropertyDefaultOutputDevice, kAudioHardwarePropertyProcessObjectList] {
                var address = CA.address(selector)
                AudioObjectAddPropertyListenerBlock(CA.system, &address, queue, block)
            }
            follow()
        }

        /// Listens to the current default output's running state (again, if it changed), and to whether each app
        /// is playing: an app that held a silent output and starts again says so only there.
        private func follow() {
            followProcesses()
            let now = CA.get(CA.system, kAudioHardwarePropertyDefaultOutputDevice, default: AudioObjectID(kAudioObjectUnknown))
            guard now != device else { return }
            unfollow()
            device = now
            guard now != kAudioObjectUnknown else { return }
            let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in self?.handler() }
            running = block
            var address = CA.address(kAudioDevicePropertyDeviceIsRunningSomewhere)
            AudioObjectAddPropertyListenerBlock(now, &address, queue, block)
        }

        private func followProcesses() {
            guard let output else { return }
            let now = Set(CA.array(CA.system, kAudioHardwarePropertyProcessObjectList))
            var address = CA.address(kAudioProcessPropertyIsRunningOutput)
            for process in now.subtracting(processes) { AudioObjectAddPropertyListenerBlock(process, &address, queue, output) }
            for process in processes.subtracting(now) { AudioObjectRemovePropertyListenerBlock(process, &address, queue, output) }
            processes = now
        }

        private func unfollow() {
            guard device != kAudioObjectUnknown, let running else { return }
            var address = CA.address(kAudioDevicePropertyDeviceIsRunningSomewhere)
            AudioObjectRemovePropertyListenerBlock(device, &address, queue, running)
            self.running = nil
        }

        /// Stops listening. On `queue`.
        public func stop() {
            unfollow()
            if let output {
                var address = CA.address(kAudioProcessPropertyIsRunningOutput)
                for process in processes { AudioObjectRemovePropertyListenerBlock(process, &address, queue, output) }
            }
            processes = []
            output = nil
            device = AudioObjectID(kAudioObjectUnknown)
            guard let system else { return }
            for selector in [kAudioHardwarePropertyDefaultOutputDevice, kAudioHardwarePropertyProcessObjectList] {
                var address = CA.address(selector)
                AudioObjectRemovePropertyListenerBlock(CA.system, &address, queue, system)
            }
            self.system = nil
        }
    }
}

/// Everything this Mac plays, except this app, as 16 kHz mono with capture times: a mono global process tap
/// read through a private aggregate device that holds only the tap (no output device in it, so a headset's mic
/// is never opened and AirPods don't drop to call quality). The IO block, on Core Audio's real-time thread, only
/// copies into a `SampleRing`; a 10 ms timer on a queue drains and resamples it, like `MicSource`.
///
/// The tap's format follows the output: when the default output or the tap's format changes (AirPods to speakers,
/// a new sample rate), the tap and its aggregate are built again for it, so the audio never plays at the wrong
/// speed. Times stay right across the gap: every block carries its own.
///
/// macOS asks for "System Audio Recording" the first time the aggregate starts. Denied, it still "works" but
/// hears silence (or the IO block never runs): `blocks` and `heardSound` tell.
// @unchecked: setup (`tap`) happens before start(); the Core Audio objects and drain state are confined to `queue`
// (start, stop and the change listeners run there too); `blocks` and `heardSound` are read through `lock`.
@available(macOS 14.2, *)
public final class MacAudioTap: LiveAudioSource, @unchecked Sendable {
    public let clock = AudioClock()
    public let chunks: AsyncStream<[Float]>
    private let continuation: AsyncStream<[Float]>.Continuation
    /// Set before `start`: where the audio goes (on the tap's queue).
    public var tap: AudioTap?
    /// Set before `start`: log that it's running (not for a short look).
    public var logs = true
    private let queue = DispatchQueue(label: "mac-audio", qos: .userInitiated)
    private var tapID = AudioObjectID(kAudioObjectUnknown)
    private var aggregateID = AudioObjectID(kAudioObjectUnknown)
    private var procID: AudioDeviceIOProcID?
    private var ring: SampleRing?
    private var timer: DispatchSourceTimer?
    private var resampler: Resampler?
    private var deviceRead = 0
    /// What the running tap was built for (nil: not running).
    private var built: Shape?
    private var listener: AudioObjectPropertyListenerBlock?
    private var rebuildPending = false
    private var stopped = false
    private let lock = NSLock()
    private var _blocks = 0
    private var _heardSound = false

    public init() {
        (chunks, continuation) = AsyncStream.makeStream(of: [Float].self, bufferingPolicy: .bufferingNewest(1))
    }

    /// IO blocks that arrived (none after a few seconds: likely no permission).
    public var blocks: Int { lock.withLock { _blocks } }
    /// Anything but exact digital silence arrived (a denied tap hears only zeros).
    public var heardSound: Bool { lock.withLock { _heardSound } }

    public func start() throws {
        var failure: Error?
        queue.sync {
            do { try build() } catch {
                teardown()
                failure = error
            }
        }
        if let failure { throw failure }
    }

    public func stop() {
        queue.async {
            self.stopped = true
            self.teardown()
            self.drain()
            self.continuation.finish()
        }
    }

    // MARK: on `queue`

    private func build() throws {
        // Leave this app out (it plays nothing, but its own sounds would count as the Mac's).
        var exclude: [AudioObjectID] = []
        var pid = getpid()
        var me = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        var address = CA.address(kAudioHardwarePropertyTranslatePIDToProcessObject)
        if AudioObjectGetPropertyData(CA.system, &address, UInt32(MemoryLayout<pid_t>.size), &pid, &size, &me) == noErr,
            me != kAudioObjectUnknown
        {
            exclude.append(me)
        }
        let description = CATapDescription(monoGlobalTapButExcludeProcesses: exclude)
        description.uuid = UUID()
        description.name = "Mac audio"
        description.isPrivate = true
        description.muteBehavior = .unmuted
        try check(AudioHardwareCreateProcessTap(description, &tapID), "create the tap")

        let output = CA.get(CA.system, kAudioHardwarePropertyDefaultOutputDevice, default: AudioObjectID(kAudioObjectUnknown))
        guard let format = tapFormat() else { throw MacAudioError.failed("couldn't read the tap's format") }
        guard format.mSampleRate > 0, format.mChannelsPerFrame > 0, format.mFormatID == kAudioFormatLinearPCM,
            format.mFormatFlags & kAudioFormatFlagIsFloat != 0, format.mBitsPerChannel == 32
        else { throw MacAudioError.failed("the tap's format isn't 32-bit float (\(format.mFormatID), \(format.mBitsPerChannel) bits)") }
        let channels = Int(format.mChannelsPerFrame)
        let interleaved = format.mFormatFlags & kAudioFormatFlagIsNonInterleaved == 0
        let stride = interleaved ? channels : 1
        guard let resampler = Resampler(rate: format.mSampleRate) else { throw MacAudioError.failed("no resampler") }
        self.resampler = resampler

        let aggregate: [String: Any] = [
            kAudioAggregateDeviceNameKey: "Mac audio",
            kAudioAggregateDeviceUIDKey: (Bundle.main.bundleIdentifier ?? "local") + ".mac-audio." + UUID().uuidString,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceIsStackedKey: false,
            kAudioAggregateDeviceTapAutoStartKey: true,
            kAudioAggregateDeviceTapListKey: [
                [kAudioSubTapUIDKey: description.uuid.uuidString, kAudioSubTapDriftCompensationKey: true]
            ],
        ]
        try check(AudioHardwareCreateAggregateDevice(aggregate as CFDictionary, &aggregateID), "create the aggregate device")

        // About 2 s of audio, so a stalled drain never makes the IO thread wait.
        let ring = SampleRing(capacity: Int(format.mSampleRate * 2))
        self.ring = ring
        deviceRead = 0
        let ticksPerFrame = Double(AVAudioTime.hostTime(forSeconds: 1)) / format.mSampleRate
        // Real-time thread (no queue given): copy into the ring and return. No allocation, locks, Objective-C or
        // dispatch.
        let io: AudioDeviceIOBlock = { _, input, inputTime, _, _ in
            let buffers = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: input))
            guard let first = buffers.first, let data = first.mData else { return }
            let n = Int(first.mDataByteSize) / (MemoryLayout<Float>.size * stride)
            guard n > 0 else { return }
            let t = inputTime.pointee
            let host = t.mFlags.contains(.hostTimeValid) ? t.mHostTime : mach_absolute_time() &- UInt64(Double(n) * ticksPerFrame)
            ring.write(data.assumingMemoryBound(to: Float.self), count: n, stride: stride, hostTime: host)
        }
        try check(AudioDeviceCreateIOProcIDWithBlock(&procID, aggregateID, nil, io), "add the audio callback")
        try check(AudioDeviceStart(aggregateID, procID), "start the tap")

        let timer = DispatchSource.makeTimerSource(flags: .strict, queue: queue)
        timer.schedule(deadline: .now() + .milliseconds(10), repeating: .milliseconds(10), leeway: .milliseconds(1))
        timer.setEventHandler { [weak self] in self?.drain() }
        timer.resume()
        self.timer = timer
        built = Shape(output: output, rate: format.mSampleRate, channels: format.mChannelsPerFrame)
        listen()
        if logs { Log.note("Mac audio tap running (\(Int(format.mSampleRate)) Hz, \(channels) ch)") }
    }

    /// The default output, and the tap's rate and channels.
    private struct Shape: Equatable {
        var output: AudioObjectID
        var rate: Double
        var channels: UInt32
    }

    private func tapFormat() -> AudioStreamBasicDescription? {
        var format = AudioStreamBasicDescription()
        var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        var address = CA.address(kAudioTapPropertyFormat)
        guard AudioObjectGetPropertyData(tapID, &address, 0, nil, &size, &format) == noErr else { return nil }
        return format
    }

    private var watched: [(AudioObjectID, AudioObjectPropertySelector)] {
        [(CA.system, kAudioHardwarePropertyDefaultOutputDevice), (tapID, kAudioTapPropertyFormat)]
    }

    /// Listens for the default output or the tap's format changing. `teardown` stops it.
    private func listen() {
        let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in self?.changed() }
        listener = block
        for (object, selector) in watched {
            var address = CA.address(selector)
            AudioObjectAddPropertyListenerBlock(object, &address, queue, block)
        }
    }

    /// Changes come in a burst (the output, then the format): build again once, when they've settled, and not from
    /// inside a listener (building removes it).
    private func changed() {
        guard !rebuildPending else { return }
        rebuildPending = true
        queue.asyncAfter(deadline: .now() + .milliseconds(300)) { [weak self] in
            guard let self else { return }
            rebuildPending = false
            rebuildIfChanged()
        }
    }

    /// Builds the tap again if the output or its format is no longer what it was built for. If that fails, no more
    /// audio comes, and the driver opens a new tap.
    private func rebuildIfChanged() {
        guard !stopped, let built else { return }
        let format = tapFormat()
        let now = Shape(
            output: CA.get(CA.system, kAudioHardwarePropertyDefaultOutputDevice, default: AudioObjectID(kAudioObjectUnknown)),
            rate: format?.mSampleRate ?? 0, channels: format?.mChannelsPerFrame ?? 0)
        guard now != built else { return }
        Log.note("Mac audio tap built again: the \(now.output != built.output ? "output" : "format") changed")
        teardown()
        drain()  // what the old one left, at its own rate
        do { try build() } catch {
            teardown()
            Log.note("Mac audio tap couldn't be built again: \(Log.describe(error))")
        }
    }

    /// Stop, then destroy in the reverse order of making.
    private func teardown() {
        if let listener {
            for (object, selector) in watched where object != kAudioObjectUnknown {
                var address = CA.address(selector)
                AudioObjectRemovePropertyListenerBlock(object, &address, queue, listener)
            }
            self.listener = nil
        }
        built = nil
        timer?.cancel()
        timer = nil
        if aggregateID != kAudioObjectUnknown {
            if let procID {
                AudioDeviceStop(aggregateID, procID)
                AudioDeviceDestroyIOProcID(aggregateID, procID)
            }
            AudioHardwareDestroyAggregateDevice(aggregateID)
        }
        if tapID != kAudioObjectUnknown { AudioHardwareDestroyProcessTap(tapID) }
        procID = nil
        aggregateID = AudioObjectID(kAudioObjectUnknown)
        tapID = AudioObjectID(kAudioObjectUnknown)
    }

    /// What the IO thread left in the ring, resampled one block at a time so each block's first sample anchors
    /// its time. Dropped blocks become silence of the same length.
    private func drain() {
        guard let ring, let resampler else { return }
        var blocks = 0
        var sound = false
        ring.drain { block, samples in
            blocks += 1
            if !sound { sound = samples.contains { $0 != 0 } }
            let gap = block.deviceIndex - deviceRead
            if gap > 0 { deliver(resampler.convert([Float](repeating: 0, count: gap)), at: nil) }
            deliver(resampler.convert(samples), at: AVAudioTime.seconds(forHostTime: block.hostTime))
            deviceRead = block.deviceIndex + block.count
        }
        guard blocks > 0 else { return }
        lock.withLock {
            _blocks += blocks
            _heardSound = _heardSound || sound
        }
    }

    private var written = 0

    private func deliver(_ samples: [Float], at host: Double?) {
        guard !samples.isEmpty else { return }
        if let host { clock.mark(index: written, hostTime: host) }
        let first = host ?? clock.hostTime(atSeconds: Double(written) / AudioClock.sampleRate) ?? hostNow()
        written += samples.count
        if let tap { tap(samples, first) } else { continuation.yield(samples) }
    }

    private func check(_ status: OSStatus, _ what: String) throws {
        guard status == noErr else { throw MacAudioError.failed("couldn't \(what) (\(status))") }
    }

    /// Asks for "System Audio Recording" (macOS only asks when a tap first starts): runs a tap for a second and
    /// stops it. Blocks while the question is on screen, so never on the main thread.
    public static func askPermission() {
        let probe = MacAudioTap()
        probe.tap = { _, _ in }
        do {
            try probe.start()
            Thread.sleep(forTimeInterval: 1)
            Log.note("asked for System Audio Recording (\(probe.blocks) blocks, \(probe.heardSound ? "sound" : "silence"))")
        } catch {
            Log.note("couldn't ask for System Audio Recording: \(Log.describe(error))")
        }
        probe.stop()
    }
}

public enum MacAudioError: Error, LocalizedError, LogSafeError {
    case failed(String)
    public var errorDescription: String? {
        switch self {
        case .failed(let why): return why
        }
    }
}

/// Any rate to 16 kHz mono, a block at a time, with reused buffers. On its owner's queue.
final class Resampler {
    private let converter: AVAudioConverter
    private let input: AVAudioFormat
    private var inBuffer: AVAudioPCMBuffer?
    private var outBuffer: AVAudioPCMBuffer?

    init?(rate: Double) {
        guard let input = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: rate, channels: 1, interleaved: false),
            let converter = AVAudioConverter(from: input, to: PCM.format16k)
        else { return nil }
        self.input = input
        self.converter = converter
    }

    func convert(_ samples: [Float]) -> [Float] {
        samples.withUnsafeBufferPointer { convert($0) }
    }

    func convert(_ samples: UnsafeBufferPointer<Float>) -> [Float] {
        guard let base = samples.baseAddress, !samples.isEmpty else { return [] }
        if (inBuffer?.frameCapacity ?? 0) < AVAudioFrameCount(samples.count) {
            let frames = AVAudioFrameCount(max(samples.count, 4096))
            inBuffer = AVAudioPCMBuffer(pcmFormat: input, frameCapacity: frames)
            outBuffer = AVAudioPCMBuffer(
                pcmFormat: PCM.format16k, frameCapacity: AVAudioFrameCount(Double(frames) * 16_000 / input.sampleRate) + 64)
        }
        guard let inBuffer, let out = outBuffer else { return [] }
        inBuffer.frameLength = AVAudioFrameCount(samples.count)
        inBuffer.floatChannelData![0].update(from: base, count: samples.count)
        out.frameLength = 0
        var given = false
        var error: NSError?
        converter.convert(to: out, error: &error) { _, status in
            if given {
                status.pointee = .noDataNow
                return nil
            }
            given = true
            status.pointee = .haveData
            return inBuffer
        }
        guard error == nil, out.frameLength > 0 else { return [] }
        return Array(UnsafeBufferPointer(start: out.floatChannelData![0], count: Int(out.frameLength)))
    }
}

/// Core Audio property reads.
enum CA {
    static let system = AudioObjectID(kAudioObjectSystemObject)

    static func address(_ selector: AudioObjectPropertySelector) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
    }

    static func get<T: BitwiseCopyable>(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector, default value: T) -> T {
        var address = address(selector)
        var size = UInt32(MemoryLayout<T>.size)
        var out = value
        guard AudioObjectGetPropertyData(object, &address, 0, nil, &size, &out) == noErr else { return value }
        return out
    }

    static func array(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector) -> [AudioObjectID] {
        var address = address(selector)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(object, &address, 0, nil, &size) == noErr, size > 0 else { return [] }
        var ids = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(object, &address, 0, nil, &size, &ids) == noErr else { return [] }
        return Array(ids.prefix(Int(size) / MemoryLayout<AudioObjectID>.size))
    }
}
