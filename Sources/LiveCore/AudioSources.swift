import AVFoundation
import FluidAudio
import Foundation
import NotesKit

/// 16 kHz mono audio arriving in order, with a clock that says when each sample was captured.
public protocol LiveAudioSource: AnyObject, Sendable {
    var clock: AudioClock { get }
    var chunks: AsyncStream<[Float]> { get }
    func start() throws
    func stop()
    /// Something waits on this audio right now (words being shown, a dictation key down): hand it over every
    /// ~10 ms. Off: ~50 ms batches are fine, which wakes everything downstream a fifth as often. Any thread.
    func setUrgent(_ on: Bool)
}

extension LiveAudioSource {
    public func setUrgent(_ on: Bool) {}
}

/// How often a source hands its audio over: every 10 ms while something waits on it, else every 50 ms.
enum Pace {
    static let urgentMs = 10
    static let calmMs = 50
}

/// Where a source sends its audio instead of `chunks` when it's the app's one mic: 16 kHz mono samples and
/// the host time (`hostNow()` seconds) their first sample was captured.
public typealias AudioTap = @Sendable (_ samples: [Float], _ hostTime: Double) -> Void

/// The mic `InputDevices` picks (the chosen one, else the built-in mic, never Bluetooth unless chosen), opened
/// straight through Core Audio: an IO proc on that one device, so the system default is neither touched nor
/// followed. (AVAudioEngine, used before, moves its input onto a "default device" aggregate whenever the default
/// output or input changes, whatever device it was set to: connecting AirPods put it on their mic, which drops them
/// to call quality, then it stopped, and a reopen in the middle of that could hang for good.) The IO proc gets audio
/// at the hardware buffer size (about 10 ms). The real-time thread only copies into a `SampleRing`; a timer on a
/// queue drains it, resamples all of it in one go and hands it over: every 10 ms while something waits on the audio
/// (`setUrgent`), else every ~50 ms.
/// It never restarts itself: when its device goes away or changes rate it calls `onChange`, and its owner reopens it.
// @unchecked: setup (`tap`, `onChange`) happens before start(); the Core Audio objects and drain state are confined
// to `queue`; `device` is set there before start() returns; `level` and `ioBufferMs` are single words read only for
// display.
public final class MicSource: LiveAudioSource, @unchecked Sendable {
    public let clock = AudioClock()
    public let chunks: AsyncStream<[Float]>
    private let continuation: AsyncStream<[Float]>.Continuation
    private let queue = DispatchQueue(label: "sona.live.mic", qos: .userInteractive)
    private var deviceID = AudioObjectID(kAudioObjectUnknown)
    private var procID: AudioDeviceIOProcID?
    private var listener: AudioObjectPropertyListenerBlock?
    /// The device's rate when it was opened: the resampler is built for it.
    private var openedRate = 0.0
    /// Core Audio can take seconds to answer while devices come and go, and has hung for good: `start` never waits
    /// longer than this. One that answers later is closed again then.
    static let openTimeout = 10.0
    private var converter: AVAudioConverter?
    private var monoFormat: AVAudioFormat?
    private var written = 0
    private var ring: SampleRing?
    private var drainTimer: DispatchSourceTimer?
    // On `queue`: reused resampler buffers, one drain's device samples, the device samples consumed so far,
    // overrun accounting, the pace.
    private var inBuffer: AVAudioPCMBuffer?
    private var outBuffer: AVAudioPCMBuffer?
    private var staged: [Float] = []
    private var deviceRead = 0
    private var gapSamples = 0
    private var loggedDropped = 0
    private var lastDropLog = 0.0
    /// Nobody said otherwise: hand audio over every 10 ms, as before pacing existed.
    private var urgent = true
    private var running = false
    private var latency: NSObjectProtocol?
    /// Latest level in dBFS, for a meter.
    public private(set) var level: Float = -90
    public private(set) var deviceDescription = ""
    public private(set) var ioBufferMs = 0.0
    /// Device samples the IO thread had to drop because the ring was full (each became silence).
    public var droppedSamples: Int { ring?.droppedSamples ?? 0 }
    /// Set before `start`: audio goes here (on the mic's queue) instead of `chunks`.
    public var tap: AudioTap?
    /// Set before `start`: its device went away or changed its sample rate. Called on the mic's queue. The owner
    /// should close this and open a new one.
    public var onChange: (@Sendable () -> Void)?
    /// The device it opened, once started.
    public private(set) var device: InputDevice?
    private let preferredUID: String?

    /// `preferredUID`: the input device's UID (`Settings.micUID`); nil picks automatically.
    public init(preferredUID: String? = nil) {
        self.preferredUID = preferredUID
        (chunks, continuation) = AsyncStream.makeStream(of: [Float].self, bufferingPolicy: .unbounded)
    }

    public func start() throws {
        let result = OpenResult()
        let done = DispatchSemaphore(value: 0)
        queue.async { [self] in
            do { try open() } catch {
                close()
                result.error = error
            }
            done.signal()
        }
        guard done.wait(timeout: .now() + Self.openTimeout) == .success else {
            // Queued behind the open, so it closes whatever that opens, whenever it gets there.
            stop()
            throw NSError(domain: "SonaLive", code: 2, userInfo: [NSLocalizedDescriptionKey: "The microphone didn't answer"])
        }
        if let error = result.error { throw error }
    }

    /// What the open on `queue` ran into, read once `start` has seen it finish.
    private final class OpenResult: @unchecked Sendable {
        var error: Error?
    }

    /// On `queue`.
    private func open() throws {
        guard let device = InputDevices.pick(preferredUID: preferredUID) else {
            throw NSError(domain: "SonaLive", code: 1, userInfo: [NSLocalizedDescriptionKey: "No microphone input"])
        }
        self.device = device
        let id = AudioObjectID(device.id)
        let couldNot = NSError(domain: "SonaLive", code: 2, userInfo: [NSLocalizedDescriptionKey: "Couldn't open \(device.name)"])
        // The IO proc gets the input in its streams' virtual format: 32-bit float at the device's rate.
        guard let format = Self.inputFormat(of: id), format.mSampleRate > 0, format.mChannelsPerFrame > 0,
            format.mFormatID == kAudioFormatLinearPCM, format.mFormatFlags & kAudioFormatFlagIsFloat != 0, format.mBitsPerChannel == 32,
            let mono = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: format.mSampleRate, channels: 1, interleaved: false),
            let converter = AVAudioConverter(from: mono, to: PCM.format16k)
        else { throw couldNot }
        self.converter = converter
        monoFormat = mono
        openedRate = format.mSampleRate
        deviceDescription = "\(device.name), \(Int(format.mSampleRate)) Hz, \(format.mChannelsPerFrame) ch"
        // About 2 s of audio, so a stalled consumer never makes the IO thread wait.
        let ring = SampleRing(capacity: Int(format.mSampleRate * 2))
        self.ring = ring
        let ticksPerFrame = Double(AVAudioTime.hostTime(forSeconds: 1)) / format.mSampleRate
        // Real-time thread (no queue given): the first channel of the first input stream into the ring, and return.
        // No allocation, locks, Objective-C or dispatch.
        let io: AudioDeviceIOBlock = { _, input, inputTime, _, _ in
            let buffers = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: input))
            guard let first = buffers.first, let data = first.mData, first.mNumberChannels > 0 else { return }
            let stride = Int(first.mNumberChannels)
            let n = Int(first.mDataByteSize) / (MemoryLayout<Float>.size * stride)
            guard n > 0 else { return }
            let t = inputTime.pointee
            let host = t.mFlags.contains(.hostTimeValid) ? t.mHostTime : mach_absolute_time() &- UInt64(Double(n) * ticksPerFrame)
            ring.write(data.assumingMemoryBound(to: Float.self), count: n, stride: stride, hostTime: host)
        }
        deviceID = id
        guard AudioDeviceCreateIOProcIDWithBlock(&procID, id, nil, io) == noErr, AudioDeviceStart(id, procID) == noErr
        else { throw couldNot }
        listen(id)
        // No App Nap while the mic is open: it could stretch the drain past what the ring holds (`pace` adds
        // latency-critical while something waits on the audio). Idle sleep isn't ours to stop: coreaudiod already
        // holds that assertion for exactly as long as the mic is open.
        activity = ProcessInfo.processInfo.beginActivity(
            options: .userInitiatedAllowingIdleSystemSleep, reason: "Recording the microphone")
        running = true
        pace()
    }

    /// The format of the device's first input stream, as its IO proc sees it.
    private static func inputFormat(of device: AudioObjectID) -> AudioStreamBasicDescription? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreams, mScope: kAudioObjectPropertyScopeInput, mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(device, &address, 0, nil, &size) == noErr, size >= UInt32(MemoryLayout<AudioStreamID>.size)
        else { return nil }
        var streams = [AudioStreamID](repeating: 0, count: Int(size) / MemoryLayout<AudioStreamID>.size)
        guard AudioObjectGetPropertyData(device, &address, 0, nil, &size, &streams) == noErr, let stream = streams.first else { return nil }
        var format = AudioStreamBasicDescription()
        var formatSize = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        var formatAddress = CA.address(kAudioStreamPropertyVirtualFormat)
        guard AudioObjectGetPropertyData(stream, &formatAddress, 0, nil, &formatSize, &format) == noErr else { return nil }
        return format
    }

    /// What's watched on the open device: it going away, its rate, its input streams.
    private static let watched: [(AudioObjectPropertySelector, AudioObjectPropertyScope)] = [
        (kAudioDevicePropertyDeviceIsAlive, kAudioObjectPropertyScopeGlobal),
        (kAudioDevicePropertyNominalSampleRate, kAudioObjectPropertyScopeGlobal),
        (kAudioDevicePropertyStreamConfiguration, kAudioObjectPropertyScopeInput),
    ]

    /// On `queue`: tells the owner when the device dies or its rate changes (the resampler is built for the old one).
    /// The default device changing is none of its business.
    private func listen(_ device: AudioObjectID) {
        let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            guard let self, self.procID != nil else { return }
            let alive = CA.get(device, kAudioDevicePropertyDeviceIsAlive, default: UInt32(0)) != 0
            if !alive || Self.inputFormat(of: device)?.mSampleRate != self.openedRate { self.onChange?() }
        }
        listener = block
        for (selector, scope) in Self.watched {
            var address = AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain)
            AudioObjectAddPropertyListenerBlock(device, &address, queue, block)
        }
    }

    /// On `queue`: stops the IO proc and lets go of the device. Safe to call twice.
    private func close() {
        if let listener {
            for (selector, scope) in Self.watched {
                var address = AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain)
                AudioObjectRemovePropertyListenerBlock(deviceID, &address, queue, listener)
            }
            self.listener = nil
        }
        if let procID {
            AudioDeviceStop(deviceID, procID)
            AudioDeviceDestroyIOProcID(deviceID, procID)
        }
        procID = nil
        deviceID = AudioObjectID(kAudioObjectUnknown)
        if let activity { ProcessInfo.processInfo.endActivity(activity) }
        activity = nil
    }

    public func setUrgent(_ on: Bool) {
        queue.async { [self] in
            guard on != urgent else { return }
            urgent = on
            pace()
            // Someone's waiting now (a dictation key just went down): what the ring holds goes out at once.
            if on { drain() }
        }
    }

    /// On `queue`: the drain timer for the pace. Urgent: strict 10 ms, with the app latency-critical, or timer
    /// coalescing could stretch it and add lag. Otherwise every 50 ms with leeway, so the system can line its
    /// wakeups up with others (the ring holds 2 s).
    private func pace() {
        drainTimer?.cancel()
        drainTimer = nil
        if urgent, running, latency == nil {
            latency = ProcessInfo.processInfo.beginActivity(
                options: [.userInitiatedAllowingIdleSystemSleep, .latencyCritical], reason: "Transcribing the microphone live")
        } else if !(urgent && running), let latency {
            ProcessInfo.processInfo.endActivity(latency)
            self.latency = nil
        }
        guard running else { return }
        let ms = urgent ? Pace.urgentMs : Pace.calmMs
        let timer = DispatchSource.makeTimerSource(flags: urgent ? .strict : [], queue: queue)
        timer.schedule(deadline: .now() + .milliseconds(ms), repeating: .milliseconds(ms), leeway: .milliseconds(urgent ? 1 : 15))
        timer.setEventHandler { [weak self] in self?.drain() }
        timer.resume()
        drainTimer = timer
    }

    /// On `queue`: takes everything the IO thread left in the ring, resamples it in one converter call and hands it
    /// over as one piece, its first sample anchoring the clock. Dropped blocks come out as silence of the same
    /// length, keeping every later sample at its real time.
    private func drain() {
        guard let ring, let monoFormat else { return }
        staged.removeAll(keepingCapacity: true)
        var first: Double?
        ring.drain { block, samples in
            let gap = block.deviceIndex - deviceRead
            if gap > 0 {
                gapSamples += gap
                staged.append(contentsOf: repeatElement(0, count: gap))
            }
            // The piece starts at the first block's capture time, less any silence standing in before it.
            if first == nil {
                first = AVAudioTime.seconds(forHostTime: block.hostTime) - Double(staged.count) / monoFormat.sampleRate
            }
            ioBufferMs = Double(block.count) / monoFormat.sampleRate * 1000
            staged.append(contentsOf: samples)
            deviceRead = block.deviceIndex + block.count
        }
        if !staged.isEmpty { process(capturedAt: first) }
        let now = hostNow()
        if gapSamples > loggedDropped, now - lastDropLog > 5 {
            lastDropLog = now
            loggedDropped = gapSamples
            Log.note(String(format: "Live mic: ring overrun, %d samples (%.0f ms) dropped so far, filled with silence",
                gapSamples, Double(gapSamples) / monoFormat.sampleRate * 1000))
        }
    }

    /// On `queue`: `staged` resampled to 16 kHz and handed over.
    private func process(capturedAt host: Double?) {
        guard let converter, let monoFormat, !staged.isEmpty else { return }
        if (inBuffer?.frameCapacity ?? 0) < AVAudioFrameCount(staged.count) {
            let frames = AVAudioFrameCount(max(staged.count, 4096))
            inBuffer = AVAudioPCMBuffer(pcmFormat: monoFormat, frameCapacity: frames)
            outBuffer = AVAudioPCMBuffer(pcmFormat: PCM.format16k, frameCapacity: AVAudioFrameCount(Double(frames) * 16_000 / monoFormat.sampleRate) + 64)
        }
        guard let inBuffer, let out = outBuffer else { return }
        inBuffer.frameLength = AVAudioFrameCount(staged.count)
        staged.withUnsafeBufferPointer { inBuffer.floatChannelData![0].update(from: $0.baseAddress!, count: $0.count) }
        out.frameLength = 0
        var given = false
        var error: NSError?
        converter.convert(to: out, error: &error) { _, status in
            if given { status.pointee = .noDataNow; return nil }
            given = true
            status.pointee = .haveData
            return inBuffer
        }
        let count = Int(out.frameLength)
        guard error == nil, count > 0 else { return }
        let converted = Array(UnsafeBufferPointer(start: out.floatChannelData![0], count: count))
        var sum: Float = 0
        for x in converted { sum += x * x }
        level = 10 * log10(max(sum / Float(count), 1e-9))
        if let host { clock.mark(index: written, hostTime: host) }
        let first = host ?? clock.hostTime(atSeconds: Double(written) / AudioClock.sampleRate) ?? hostNow()
        written += count
        if let tap { tap(converted, first) } else { continuation.yield(converted) }
    }

    private var activity: NSObjectProtocol?

    /// Never waits on Core Audio: the device is let go of on the mic's queue (after an open that's still going, if
    /// `start` gave up on it). Audio that comes in meanwhile is the owner's to ignore.
    public func stop() {
        queue.async {
            self.close()
            self.running = false
            self.pace()
            // The IO proc has stopped: take the last of the ring, then end the stream.
            self.drain()
            if let dropped = self.ring?.droppedSamples, dropped > 0 { Log.note("Live mic stopped: \(dropped) samples dropped in all") }
            self.continuation.finish()
        }
    }
}

/// Plays a file into the engine at real-time speed, as if it were the mic: 10 ms at a time, or 50 ms while nothing
/// waits on it (`setUrgent`), like the mic. For benchmarks and test runs of the app (`thenSilence`: then a quiet
/// room until stopped, so a conversation can end).
// @unchecked: `samples` is immutable; `tap` and `thread` are only set before start() / read in stop() by the owner.
public final class FileSource: LiveAudioSource, @unchecked Sendable {
    public let clock = AudioClock()
    public let chunks: AsyncStream<[Float]>
    private let continuation: AsyncStream<[Float]>.Continuation
    private let samples: [Float]
    private let thenSilence: Bool
    private let startHost: Double?
    private var thread: Thread?
    /// Nobody said otherwise: every 10 ms, as before pacing existed.
    private let pace = PaceSignal(urgent: true)
    /// Set before `start`: audio goes here instead of `chunks`.
    public var tap: AudioTap?
    public var duration: Double { Double(samples.count) / AudioClock.sampleRate }

    /// `startHost`: the host time its first sample counts as captured (two test files played side by side, as
    /// the mic and the Mac's audio, share one); it then catches up if that's passed. Nil: now.
    public init(url: URL, thenSilence: Bool = false, startHost: Double? = nil) throws {
        samples = try AudioConverter().resampleAudioFile(url)
        self.thenSilence = thenSilence
        self.startHost = startHost
        (chunks, continuation) = AsyncStream.makeStream(of: [Float].self, bufferingPolicy: .unbounded)
    }

    public func start() throws {
        let samples = samples, clock = clock, continuation = continuation, tap = tap, thenSilence = thenSilence
        let pace = pace
        let t0 = startHost ?? hostNow() + 0.05
        let thread = Thread {
            let block = Int(AudioClock.sampleRate) * Pace.urgentMs / 1000
            let rate = AudioClock.sampleRate
            var i = 0
            while i < samples.count || thenSilence, !Thread.current.isCancelled {
                let urgent = pace.urgent
                let batch = urgent ? block : block * Pace.calmMs / Pace.urgentMs
                var end = i < samples.count ? min(i + batch, samples.count) : i + batch
                // A piece "arrives" once its last sample has been spoken.
                let due = t0 + Double(end) / rate
                if urgent {
                    let wait = due - hostNow()
                    if wait > 0 { usleep(useconds_t(wait * 1_000_000)) }
                } else if !pace.waitCalm(until: due) {
                    // Turned urgent meanwhile (a dictation key went down): what has arrived goes now, in whole blocks.
                    let arrived = Int((hostNow() - t0) * rate)
                    end = min(end, i + max(arrived - i, 0) / block * block)
                    if end <= i { continue }
                }
                let host = t0 + Double(i) / rate
                clock.mark(index: i, hostTime: host)
                var piece = i < samples.count ? Array(samples[i..<min(end, samples.count)]) : []
                if end > samples.count { piece.append(contentsOf: repeatElement(0, count: end - max(i, samples.count))) }
                if let tap { tap(piece, host) } else { continuation.yield(piece) }
                i = end
            }
            continuation.finish()
        }
        thread.qualityOfService = .userInteractive
        self.thread = thread
        thread.start()
    }

    public func setUrgent(_ on: Bool) { pace.set(on) }

    public func stop() {
        thread?.cancel()
    }
}

/// A source thread's pace, which can wake it from a calm sleep the moment it turns urgent.
// @unchecked: `on` is under `condition`.
final class PaceSignal: @unchecked Sendable {
    private let condition = NSCondition()
    private var on: Bool

    init(urgent: Bool) { on = urgent }

    var urgent: Bool { condition.withLock { on } }

    func set(_ urgent: Bool) {
        condition.withLock {
            on = urgent
            condition.broadcast()
        }
    }

    /// Sleeps until host time `deadline`. False if it turned urgent first.
    func waitCalm(until deadline: Double) -> Bool {
        condition.withLock {
            while !on {
                let left = deadline - hostNow()
                if left <= 0 { return true }
                condition.wait(until: Date(timeIntervalSinceNow: left))
            }
            return false
        }
    }
}

/// A live session's audio, pushed in by the app's one mic. The mic outlives sessions and is reopened as devices
/// come and go (or only opened while the dictation key is down); the relay gives the session one continuous
/// stream and one clock across all of that: each push is anchored at its real capture time, so a gap (a reopen,
/// a closed mic) never shifts the times of later words.
// @unchecked: `written`, `lastPush`, the kept audio, the yields and the pace are under `lock`, so pushes from different
// threads stay in order.
public final class RelaySource: LiveAudioSource, @unchecked Sendable {
    public let clock = AudioClock()
    public let chunks: AsyncStream<[Float]>
    private let continuation: AsyncStream<[Float]>.Continuation
    private let lock = NSLock()
    private var written = 0
    private var lastPush = -Double.infinity
    /// The last `recentSeconds` of audio (and everything from `keepFrom` on while a dictation wants it), so a
    /// dictation can transcribe its own clip, starting a little before the key went down. `kept[0]` is sample `keptStart`.
    private var kept: [Float] = []
    private var keptStart = 0
    private var keepFrom: Int?
    public static let recentSeconds = 2.0
    /// What the session last asked for (`setUrgent`), and who to tell: the mic feeding this relay.
    private var urgent = false
    private var pacer: (@Sendable (Bool) -> Void)?

    public init() {
        (chunks, continuation) = AsyncStream.makeStream(of: [Float].self, bufferingPolicy: .unbounded)
    }

    /// The source feeding this relay sets its own pace from the session's wish: told it now, and on every change
    /// (on the caller's thread, in order). Nil stops that.
    public func paced(by pacer: (@Sendable (Bool) -> Void)?) {
        lock.withLock {
            self.pacer = pacer
            pacer?(urgent)
        }
    }

    public func setUrgent(_ on: Bool) {
        lock.withLock {
            guard on != urgent else { return }
            urgent = on
            pacer?(on)
        }
    }

    public func push(_ samples: [Float], hostTime: Double) {
        guard !samples.isEmpty else { return }
        lock.withLock {
            clock.mark(index: written, hostTime: hostTime)
            written += samples.count
            lastPush = hostNow()
            kept.append(contentsOf: samples)
            // Dropped a second at a time, so this stays cheap.
            let floor = min(keepFrom ?? .max, written - Int(Self.recentSeconds * AudioClock.sampleRate))
            if floor - keptStart >= Int(AudioClock.sampleRate) {
                kept.removeFirst(floor - keptStart)
                keptStart = floor
            }
            continuation.yield(samples)
        }
    }

    /// Keep all audio from session second `seconds` on (a dictation's clip), or only the last couple of seconds (nil).
    public func keep(from seconds: Double?) {
        lock.withLock { keepFrom = seconds.map { max(0, Int($0 * AudioClock.sampleRate)) } }
    }

    /// The audio between two session seconds, as far as it has arrived and is still kept.
    public func audio(from: Double, to: Double) -> [Float] {
        lock.withLock {
            let a = max(Int(from * AudioClock.sampleRate), keptStart), b = min(Int(to * AudioClock.sampleRate), written)
            guard a < b else { return [] }
            return Array(kept[(a - keptStart)..<(b - keptStart)])
        }
    }

    /// Session seconds just after the last sample pushed: where the next audio will start.
    public var endSeconds: Double { lock.withLock { Double(written) / AudioClock.sampleRate } }

    /// Audio is arriving right now (pushed in the last quarter second).
    public var isFlowing: Bool { lock.withLock { hostNow() - lastPush < 0.25 } }

    public func start() throws {}
    public func stop() { continuation.finish() }
}

/// A lock-free single-producer, single-consumer ring of mono samples for the mic's real-time thread.
/// The producer (Core Audio's IO thread) only copies samples and a mark per block (where the block starts in the
/// device's own sample count, and its host time); it never allocates, locks or dispatches. If the ring is full the
/// block is dropped and counted, but the device sample count still advances, so the consumer sees the gap and can
/// keep the clock honest. Indices only grow; positions are taken modulo the capacity.
///
/// Built on aligned word loads and stores with `OSMemoryBarrier` for ordering (`Atomic` needs macOS 15).
// @unchecked: SPSC by design (see above): each shared word has one writer, ordered with memory barriers.
public final class SampleRing: @unchecked Sendable {
    /// One block as the IO thread delivered it.
    public struct Block {
        /// Index of the block's first sample in everything the device produced (dropped blocks included).
        public var deviceIndex: Int
        /// Mach host time of the block's first sample.
        public var hostTime: UInt64
        public var count: Int
    }

    public let capacity: Int
    public let blockCapacity: Int
    private let samples: UnsafeMutablePointer<Float>
    private let marks: UnsafeMutablePointer<Block>
    /// Shared words: written by one side only, read by the other.
    private let shared: UnsafeMutablePointer<Int>
    private static let marksWritten = 0, samplesRead = 1, marksRead = 2, dropped = 3
    // Producer-only.
    private var samplesWritten = 0
    private var deviceIndex = 0
    // Consumer-only.
    private var scratch: [Float] = []

    /// `capacity` samples (size it for ~2 s at the device rate); `blockCapacity` IO blocks in flight.
    public init(capacity: Int, blockCapacity: Int = 4096) {
        precondition(capacity > 0 && blockCapacity > 0)
        self.capacity = capacity
        self.blockCapacity = blockCapacity
        samples = .allocate(capacity: capacity)
        samples.initialize(repeating: 0, count: capacity)
        marks = .allocate(capacity: blockCapacity)
        marks.initialize(repeating: Block(deviceIndex: 0, hostTime: 0, count: 0), count: blockCapacity)
        shared = .allocate(capacity: 4)
        shared.initialize(repeating: 0, count: 4)
    }

    deinit {
        samples.deallocate()
        marks.deallocate()
        shared.deallocate()
    }

    /// Samples dropped because the ring was full (read from either side; may lag by a block).
    public var droppedSamples: Int { shared[Self.dropped] }

    /// Producer side, real-time safe. Copies `count` samples taken every `stride` floats from `source`
    /// (the first channel of interleaved audio). Returns false if the block didn't fit and was dropped.
    @discardableResult
    public func write(_ source: UnsafePointer<Float>, count: Int, stride: Int = 1, hostTime: UInt64) -> Bool {
        let start = deviceIndex
        deviceIndex += count
        guard count > 0 else { return true }
        let read = shared[Self.samplesRead]
        let marksRead = shared[Self.marksRead]
        // Acquire: the consumer's reads of the space we're about to reuse are done.
        OSMemoryBarrier()
        let marksWritten = shared[Self.marksWritten]
        guard count <= capacity - (samplesWritten - read), marksWritten - marksRead < blockCapacity else {
            shared[Self.dropped] += count
            return false
        }
        var at = samplesWritten % capacity
        if stride == 1 {
            let first = min(count, capacity - at)
            (samples + at).update(from: source, count: first)
            if first < count { samples.update(from: source + first, count: count - first) }
        } else {
            for i in 0..<count {
                samples[at] = source[i * stride]
                at += 1
                if at == capacity { at = 0 }
            }
        }
        marks[marksWritten % blockCapacity] = Block(deviceIndex: start, hostTime: hostTime, count: count)
        samplesWritten += count
        // Release: the samples and mark are in memory before the consumer can see them.
        OSMemoryBarrier()
        shared[Self.marksWritten] = marksWritten + 1
        return true
    }

    /// Consumer side: hands over every complete block in order, as a contiguous buffer valid only during the call.
    public func drain(_ body: (Block, UnsafeBufferPointer<Float>) -> Void) {
        let marksWritten = shared[Self.marksWritten]
        // Acquire: see the samples and marks published with that count.
        OSMemoryBarrier()
        var marksRead = shared[Self.marksRead]
        var read = shared[Self.samplesRead]
        while marksRead < marksWritten {
            let block = marks[marksRead % blockCapacity]
            if scratch.count < block.count { scratch = [Float](repeating: 0, count: block.count) }
            let at = read % capacity
            let first = min(block.count, capacity - at)
            scratch.withUnsafeMutableBufferPointer { out in
                out.baseAddress!.update(from: samples + at, count: first)
                if first < block.count { (out.baseAddress! + first).update(from: samples, count: block.count - first) }
                body(block, UnsafeBufferPointer(rebasing: out[0..<block.count]))
            }
            read += block.count
            marksRead += 1
        }
        // Release: done reading before the producer may overwrite.
        OSMemoryBarrier()
        shared[Self.samplesRead] = read
        shared[Self.marksRead] = marksRead
    }
}
