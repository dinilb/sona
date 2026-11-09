#if os(macOS)
import CoreAudio
#endif
import Foundation

/// Is this Mac itself playing something the mic can hear (a YouTube video, a podcast, a show)? If it was
/// for most of a conversation's speech, the "conversation" is likely that media, and the note says so.
/// Nothing is ever dropped for it: the note is only marked, so AIs can skip it.
///
/// Only sampled while a conversation is open (about once a second), so it costs nothing when the room is quiet.
public enum Playback {
    public struct Sample: Equatable, Sendable {
        /// Another app is playing, unmuted, to speakers the mic can hear (built-in, HDMI/DisplayPort, AirPlay).
        public var playing: Bool
        /// Some app is both recording and playing: a call (Zoom, FaceTime, Meet). Real people, not media.
        public var call: Bool

        public init(playing: Bool, call: Bool) {
            self.playing = playing
            self.call = call
        }
    }

    /// A note is marked as likely media when this Mac played audio during at least this share of its speech.
    public static let threshold = 0.8

    /// Why a conversation is likely media, or nil if it isn't. `fraction`: SpoolEntry.playback.
    public static func mediaReason(fraction: Double?) -> String? {
        guard let fraction, fraction >= threshold else { return nil }
        return "this Mac was playing audio during \(Int((fraction * 100).rounded()))% of the speech"
    }

    /// Counts a conversation's speech against what the Mac was playing.
    public struct Tally: Equatable, Sendable {
        var speech = 0
        var playing = 0

        public init() {}

        /// One speech chunk, with the latest sample (nil: no sample, like a file in `simulate`).
        public mutating func add(speechWith sample: Sample?) {
            guard let sample else { return }
            speech += 1
            if sample.playing, !sample.call { playing += 1 }
        }

        /// Share of the sampled speech during which this Mac played audio; nil if nothing was sampled.
        public var fraction: Double? { speech == 0 ? nil : Double(playing) / Double(speech) }
    }

    // Core Audio process and device queries exist only on the Mac.
    #if os(macOS)
    /// The real check. Usually a couple of Core Audio calls (is the output running?); the process list (~3 ms) is
    /// only read when it is. A call counts on any output (headphones too: with this Mac's audio heard as its own
    /// track, a call's other side shouldn't make a note "media"); playing only counts on speakers the mic hears.
    public static func sample() -> Sample {
        let none = Sample(playing: false, call: false)
        let system = AudioObjectID(kAudioObjectSystemObject)
        let output: AudioObjectID = get(system, kAudioHardwarePropertyDefaultOutputDevice) ?? 0
        guard output != 0, (get(output, kAudioDevicePropertyDeviceIsRunningSomewhere) ?? UInt32(0)) != 0 else { return none }
        let speakers = audible(output)

        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyProcessObjectList, mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(system, &address, 0, nil, &size) == noErr, size > 0 else { return none }
        var ids = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(system, &address, 0, nil, &size, &ids) == noErr else { return none }

        let me = getpid()
        var result = none
        for id in ids {
            guard (get(id, kAudioProcessPropertyIsRunningOutput) ?? UInt32(0)) != 0 else { continue }
            guard let pid: pid_t = get(id, kAudioProcessPropertyPID), pid != me else { continue }
            if (get(id, kAudioProcessPropertyIsRunningInput) ?? UInt32(0)) != 0 { result.call = true }
            // Only an app playing to these speakers (not, say, Zoom on a headset while something else
            // keeps the speakers awake).
            if speakers, !result.playing, devices(of: id).contains(output) { result.playing = true }
        }
        return result
    }

    /// Speakers the mic can hear, by allowlist: the built-in speakers (not the headphone jack), a display's
    /// speakers, or AirPlay; and not muted or turned right down. Everything else (Bluetooth, USB and
    /// Thunderbolt headsets, aggregates, virtual devices) counts as not heard: a missed mark is harmless,
    /// a wrong one hides a real conversation.
    static func audible(_ device: AudioObjectID) -> Bool {
        let transport: UInt32 = get(device, kAudioDevicePropertyTransportType) ?? 0
        switch transport {
        case kAudioDeviceTransportTypeBuiltIn:
            let source: UInt32? = get(device, kAudioDevicePropertyDataSource, scope: kAudioDevicePropertyScopeOutput)
            if source == 0x6864_706E { return false }  // 'hdpn', headphones
        case kAudioDeviceTransportTypeHDMI, kAudioDeviceTransportTypeDisplayPort, kAudioDeviceTransportTypeAirPlay:
            break
        default:
            return false
        }
        if (get(device, kAudioDevicePropertyMute, scope: kAudioDevicePropertyScopeOutput) ?? UInt32(0)) != 0 { return false }
        // 'vmvc', the main volume slider (kAudioHardwareServiceDeviceProperty_VirtualMainVolume).
        if let volume: Float32 = get(device, 0x766D_7663, scope: kAudioDevicePropertyScopeOutput), volume < 0.05 { return false }
        return true
    }

    /// The output devices a process is playing to.
    static func devices(of process: AudioObjectID) -> [AudioObjectID] {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioProcessPropertyDevices, mScope: kAudioObjectPropertyScopeOutput, mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(process, &address, 0, nil, &size) == noErr, size > 0 else { return [] }
        var ids = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(process, &address, 0, nil, &size, &ids) == noErr else { return [] }
        return ids
    }

    private static func get<T: BitwiseCopyable>(
        _ object: AudioObjectID, _ selector: AudioObjectPropertySelector,
        scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal
    ) -> T? {
        var address = AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain)
        var size = UInt32(MemoryLayout<T>.size)
        let value = UnsafeMutablePointer<T>.allocate(capacity: 1)
        defer { value.deallocate() }
        guard AudioObjectGetPropertyData(object, &address, 0, nil, &size, value) == noErr else { return nil }
        return value.pointee
    }
    #endif
}
