// Core Audio devices exist only on the Mac; the iPhone app records through AVAudioSession instead.
#if os(macOS)
import CoreAudio
import Foundation

/// One audio input device as Core Audio sees it.
public struct InputDevice: Equatable, Sendable {
    public var id: UInt32
    /// Stable across reboots and reconnects. This is what settings store.
    public var uid: String
    public var name: String
    /// `kAudioDeviceTransportType...` (built-in, USB, Bluetooth, Bluetooth LE, virtual...).
    public var transport: UInt32
    /// The Mac's system default input right now.
    public var isDefault: Bool

    public init(id: UInt32, uid: String, name: String, transport: UInt32, isDefault: Bool = false) {
        self.id = id
        self.uid = uid
        self.name = name
        self.transport = transport
        self.isDefault = isDefault
    }

    public var isBuiltIn: Bool { transport == kAudioDeviceTransportTypeBuiltIn }
    /// Opening a Bluetooth mic switches AirPods and other headsets into call mode (HFP), which wrecks their audio.
    public var isBluetooth: Bool { transport == kAudioDeviceTransportTypeBluetooth || transport == kAudioDeviceTransportTypeBluetoothLE }
    /// For logs: what kind of device it is ("built-in", "Bluetooth", "USB"...), never its name, which is often the
    /// owner's ("Someone's AirPods"), and log lines get pasted.
    public var label: String {
        if isBuiltIn { return "built-in" }
        if isBluetooth { return "Bluetooth" }
        switch transport {
        case kAudioDeviceTransportTypeUSB: return "USB"
        case kAudioDeviceTransportTypeVirtual: return "virtual"
        case kAudioDeviceTransportTypeAggregate: return "aggregate"
        default: return "other"
        }
    }
}

/// Lists input devices and picks which one to record from, so a Bluetooth headset is never opened by accident.
public enum InputDevices {
    /// Which input to use:
    /// 1. the chosen device (`preferredUID`) if it's connected, Bluetooth or not;
    /// 2. otherwise the system default input, unless it's Bluetooth (a USB mic, or the built-in one);
    /// 3. otherwise the built-in mic.
    /// Bluetooth inputs are only ever used when chosen. Nil: nothing usable.
    public static func choose(from devices: [InputDevice], preferredUID: String?) -> InputDevice? {
        if let preferredUID, let chosen = devices.first(where: { $0.uid == preferredUID }) { return chosen }
        if let system = devices.first(where: { $0.isDefault && !$0.isBluetooth }) { return system }
        return devices.first(where: \.isBuiltIn)
    }

    /// The device `choose` picks on this Mac right now.
    public static func pick(preferredUID: String?) -> InputDevice? {
        choose(from: list(), preferredUID: preferredUID)
    }

    /// Every device with at least one input stream, in Core Audio's order.
    public static func list() -> [InputDevice] {
        let system = AudioObjectID(kAudioObjectSystemObject)
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(system, &address, 0, nil, &size) == noErr, size > 0 else { return [] }
        var ids = [AudioDeviceID](repeating: 0, count: Int(size) / MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(system, &address, 0, nil, &size, &ids) == noErr else { return [] }
        let defaultID = defaultInputID()
        return ids.compactMap { id in
            guard hasInput(id), let uid = string(id, kAudioDevicePropertyDeviceUID) else { return nil }
            let name = string(id, kAudioObjectPropertyName) ?? uid
            return InputDevice(id: id, uid: uid, name: name, transport: transport(id), isDefault: id == defaultID)
        }
    }

    /// Calls `handler` on `queue` whenever devices come or go, or the default input changes.
    /// Keep the returned token; pass it to `stopWatching` when done.
    public static func watch(queue: DispatchQueue, _ handler: @escaping @Sendable () -> Void) -> Watch {
        let block: AudioObjectPropertyListenerBlock = { _, _ in handler() }
        var listened: [AudioObjectPropertySelector] = []
        for selector in [kAudioHardwarePropertyDevices, kAudioHardwarePropertyDefaultInputDevice] {
            var address = AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
            let status = AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &address, queue, block)
            if status == noErr { listened.append(selector) } else { Log.note("couldn't watch audio devices (\(selector)): \(status)") }
        }
        return Watch(queue: queue, block: block, selectors: listened)
    }

    public static func stopWatching(_ watch: Watch) {
        for selector in watch.selectors {
            var address = AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
            AudioObjectRemovePropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &address, watch.queue, watch.block)
        }
    }

    public struct Watch: @unchecked Sendable {
        let queue: DispatchQueue
        let block: AudioObjectPropertyListenerBlock
        let selectors: [AudioObjectPropertySelector]
    }

    // MARK: Core Audio

    private static func defaultInputID() -> AudioDeviceID {
        var device = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &device) == noErr else { return 0 }
        return device
    }

    private static func hasInput(_ id: AudioDeviceID) -> Bool {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreams, mScope: kAudioObjectPropertyScopeInput, mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        return AudioObjectGetPropertyDataSize(id, &address, 0, nil, &size) == noErr && size > 0
    }

    private static func transport(_ id: AudioDeviceID) -> UInt32 {
        var value = UInt32(0)
        var size = UInt32(MemoryLayout<UInt32>.size)
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyTransportType, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, &value) == noErr else { return 0 }
        return value
    }

    private static func string(_ id: AudioDeviceID, _ selector: AudioObjectPropertySelector) -> String? {
        var value: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        var address = AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, &value) == noErr, let value else { return nil }
        return value.takeRetainedValue() as String
    }
}
#endif
