import AppKit
import CoreGraphics
import LiveCore
import NotesKit

/// Watches the keyboard for the dictation shortcut, and records a new one for Settings. It's a CGEventTap at the
/// session level, put ahead of other apps' taps, so one that swallows or rewrites keys can't hide them. Which keys
/// are down comes from the events themselves, never from `CGEventSource.keyState` (it says false for a held
/// modifier). The tap has its own thread: every key press on the Mac waits for it, so it never waits on the main one.
///
/// Modifier presses always go through (other apps and ⌘ shortcuts need them); only the key of a modifiers-plus-key
/// shortcut is swallowed, with its repeats and its key-up, so nothing gets typed.
final class KeyMonitor: @unchecked Sendable {
    static let shared = KeyMonitor()

    enum Event: Sendable {
        /// The shortcut went down or up, at this `hostNow()` time (from the event's own timestamp).
        case down(Double), up(Double)
        /// Another key or modifier while it was held: it wasn't dictation.
        case interrupted
    }

    enum Recorded: Sendable {
        case shortcut(DictationShortcut)
        /// Not allowed (a bare letter); it keeps listening.
        case refused(String)
        case cancelled
    }

    /// Set and called on the main thread only.
    nonisolated(unsafe) var onEvent: @MainActor (Event) -> Void = { _ in }
    nonisolated(unsafe) private var onRecord: (@MainActor (Recorded) -> Void)?

    private let lock = NSLock()
    private var tracker = KeyTracker()
    private var tap: CFMachPort?
    private var loop: CFRunLoop?
    private var tapSwallows = false
    /// Which recording a timeout belongs to.
    nonisolated(unsafe) private var recordings = 0  // main thread only

    /// Test runs (LIVE_FILE, LIVE_SNAPSHOT, any SONA_HOME test home) never watch the keyboard or remap a key; only
    /// the key probe, asked for by name, does.
    static var mayTouchKeyboard: Bool { !TestRun.isOn && (!Paths.isTestHome || KeyProbe.isOn) }

    /// Watch for this shortcut (nil: none). The tap only runs while there's one, or while recording.
    @MainActor func watch(_ shortcut: DictationShortcut?) {
        let outputs = lock.withLock { tracker.watch(shortcut) }
        deliver(outputs, at: hostNow())
        refresh()
    }

    /// Records the next shortcut pressed, until it's one that's allowed or Esc, for at most 15 seconds. It only
    /// listens: nothing is swallowed meanwhile, so a recording left running can never take the keyboard. The
    /// dictation shortcut doesn't fire meanwhile. Caps Lock should already be remapped (`CapsLockKey`).
    @MainActor func record(_ done: @escaping @MainActor (Recorded) -> Void) {
        onRecord = done
        recordings += 1
        let this = recordings
        let outputs = lock.withLock { tracker.startRecording() }
        deliver(outputs, at: hostNow())
        refresh()
        DispatchQueue.main.asyncAfter(deadline: .now() + 15) { [self] in
            MainActor.assumeIsolated {
                guard recordings == this, let done = onRecord else { return }
                stopRecording()
                done(.cancelled)
            }
        }
    }

    @MainActor func stopRecording() {
        onRecord = nil
        lock.withLock { tracker.recording = nil }
        refresh()
    }

    /// Asked by dictation's safety timer: is the shortcut still held? Our own state, checked against the modifier
    /// flags the system has from the keyboard: if they say a modifier it needs is up, we missed its key-up.
    func isStillDown() -> Bool {
        let flags = CGEventSource.flagsState(.hidSystemState).rawValue
        return lock.withLock { tracker.checkStillDown(flags: flags) }
    }

    /// Caps Lock is remapped to F18, so F18 is Caps Lock held.
    func capsRemapped(_ on: Bool) {
        lock.withLock { tracker.capsIsF18 = on }
    }

    // MARK: the tap

    /// Starts, stops or swaps the tap for what's needed now. It only listens unless the shortcut has a key (or Caps
    /// Lock, held as F18) to swallow: a tap that can swallow holds up every key press on the Mac until it answers.
    @MainActor private func refresh() {
        let (wanted, swallows) = lock.withLock { () -> (Bool, Bool) in
            (tracker.shortcut != nil || tracker.recording != nil, tracker.swallows)
        }
        guard wanted, Self.mayTouchKeyboard else { return stop() }
        if lock.withLock({ tap != nil && tapSwallows != swallows }) { stop() }
        start(swallows: swallows)
    }

    @MainActor private func start(swallows: Bool) {
        guard lock.withLock({ tap == nil }) else { return }
        let ready = DispatchSemaphore(value: 0)
        let thread = Thread { [self] in run(ready, swallows: swallows) }
        thread.name = "Sona keys"
        thread.qualityOfService = .userInteractive
        thread.start()
        ready.wait()
    }

    @MainActor private func stop() {
        let (tap, loop) = lock.withLock { () -> (CFMachPort?, CFRunLoop?) in
            defer { (self.tap, self.loop) = (nil, nil) }
            return (self.tap, self.loop)
        }
        guard let tap, let loop else { return }
        CGEvent.tapEnable(tap: tap, enable: false)
        // A block, not a bare CFRunLoopStop: a stop that lands before the loop is entered would be lost (handy-keys).
        CFRunLoopPerformBlock(loop, CFRunLoopMode.commonModes.rawValue) { CFRunLoopStop(CFRunLoopGetCurrent()) }
        CFRunLoopWakeUp(loop)
    }

    private func run(_ ready: DispatchSemaphore, swallows: Bool) {
        let mask: CGEventMask = (1 << CGEventType.keyDown.rawValue) | (1 << CGEventType.keyUp.rawValue) | (1 << CGEventType.flagsChanged.rawValue)
        let me = Unmanaged.passUnretained(self).toOpaque()
        guard
            let tap = CGEvent.tapCreate(
                tap: .cgSessionEventTap, place: .headInsertEventTap, options: swallows ? .defaultTap : .listenOnly,
                eventsOfInterest: mask,
                callback: { _, type, event, me in
                    guard let me else { return Unmanaged.passUnretained(event) }
                    let monitor = Unmanaged<KeyMonitor>.fromOpaque(me).takeUnretainedValue()
                    return monitor.handle(type, event) ? nil : Unmanaged.passUnretained(event)
                }, userInfo: me)
        else {
            Log.note("dictation: couldn't watch the keyboard (no Accessibility?)")
            ready.signal()
            return
        }
        let source = CFMachPortCreateRunLoopSource(nil, tap, 0)
        let loop = CFRunLoopGetCurrent()!
        CFRunLoopAddSource(loop, source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        lock.withLock {
            self.tap = tap
            self.loop = loop
            self.tapSwallows = swallows
        }
        ready.signal()
        // No polling here (handy-keys found asking CGEventTapIsEnabled over and over leaks kernel IPC until macOS
        // panics): a disabled tap is turned back on from its own callback.
        CFRunLoopRun()
        CFMachPortInvalidate(tap)
        CFRunLoopRemoveSource(loop, source, .commonModes)
    }

    /// On the tap's thread, and every key press waits for it (when it can swallow): no I/O, no waiting on the main
    /// thread, and the lock is only ever held for a few field updates. True: swallow the event.
    private func handle(_ type: CGEventType, _ event: CGEvent) -> Bool {
        let flags = event.flags.rawValue
        // Event timestamps are nanoseconds on the host clock, the clock `hostNow()` reads.
        let time = event.timestamp == 0 ? hostNow() : Double(event.timestamp) / 1e9
        let code = UInt16(truncatingIfNeeded: event.getIntegerValueField(.keyboardEventKeycode))
        let (swallow, outputs): (Bool, [KeyTracker.Output])
        switch type {
        case .tapDisabledByTimeout, .tapDisabledByUserInput:
            if let tap = lock.withLock({ tap }) { CGEvent.tapEnable(tap: tap, enable: true) }
            // Whatever happened meanwhile wasn't seen: anything not still held per the system is up.
            let now = CGEventSource.flagsState(.hidSystemState).rawValue
            (swallow, outputs) = (false, lock.withLock { tracker.lostTrack(flags: now) })
        case .flagsChanged:
            (swallow, outputs) = (false, lock.withLock { tracker.flagsChanged(code: code, flags: flags) })
        case .keyDown, .keyUp:
            let isRepeat = event.getIntegerValueField(.keyboardEventAutorepeat) != 0
            (swallow, outputs) = lock.withLock { tracker.key(code: code, down: type == .keyDown, isRepeat: isRepeat, flags: flags) }
        default:
            return false
        }
        if !outputs.isEmpty { deliver(outputs, at: time) }
        return swallow
    }

    private func deliver(_ outputs: [KeyTracker.Output], at time: Double) {
        guard !outputs.isEmpty else { return }
        DispatchQueue.main.async {
            MainActor.assumeIsolated {
                for output in outputs {
                    switch output {
                    case .down: self.onEvent(.down(time))
                    case .up: self.onEvent(.up(time))
                    case .interrupted: self.onEvent(.interrupted)
                    case .recorded(let result):
                        let done = self.onRecord
                        if case .refused = result {} else { self.stopRecording() }
                        done?(result)
                    }
                }
            }
        }
    }
}

/// What's held and whether the shortcut is, from key events alone. No system calls, so it reads like the rules.
struct KeyTracker {
    typealias Modifiers = DictationShortcut.Modifiers

    enum Output { case down, up, interrupted, recorded(KeyMonitor.Recorded) }

    struct Recording {
        /// Every modifier held since the first went down.
        var peak: Modifiers = []
    }

    private(set) var shortcut: DictationShortcut?
    var recording: Recording?

    /// Only a shortcut's key (or Caps Lock held as F18) is ever swallowed, and never while recording.
    var swallows: Bool {
        guard recording == nil, let shortcut else { return false }
        return shortcut.key != nil || shortcut.usesCapsLock
    }
    /// While Caps Lock is remapped, its key arrives as F18.
    var capsIsF18 = false
    private(set) var held: Modifiers = []
    private(set) var active = false
    /// Interrupted: it can't start again until its keys are let go.
    private var spoiled = false
    /// The shortcut's key: its repeats and key-up are swallowed until it comes up.
    private var swallowing: UInt16?

    static let f18: UInt16 = 79
    static let esc: UInt16 = 53

    // Device-independent flags (CGEventFlags) and the device-dependent side bits (NX_DEVICE*KEYMASK).
    static let fnFlag: UInt64 = 0x80_0000
    /// Per modifier key code: its side, the other side, their bits, and the group's flag.
    static let sides: [UInt16: (mine: Modifiers, other: Modifiers, myBit: UInt64, otherBit: UInt64, flag: UInt64)] = [
        55: (.leftCommand, .rightCommand, 0x08, 0x10, 0x10_0000), 54: (.rightCommand, .leftCommand, 0x10, 0x08, 0x10_0000),
        58: (.leftOption, .rightOption, 0x20, 0x40, 0x8_0000), 61: (.rightOption, .leftOption, 0x40, 0x20, 0x8_0000),
        59: (.leftControl, .rightControl, 0x01, 0x2000, 0x4_0000), 62: (.rightControl, .leftControl, 0x2000, 0x01, 0x4_0000),
        56: (.leftShift, .rightShift, 0x02, 0x04, 0x2_0000), 60: (.rightShift, .leftShift, 0x04, 0x02, 0x2_0000),
    ]
    static let groupFlags: [(Modifiers, UInt64)] = [(.command, 0x10_0000), (.option, 0x8_0000), (.control, 0x4_0000), (.shift, 0x2_0000)]

    mutating func watch(_ new: DictationShortcut?) -> [Output] {
        guard new != shortcut else { return [] }
        shortcut = new
        swallowing = nil
        spoiled = false
        return deactivate(.interrupted)
    }

    mutating func startRecording() -> [Output] {
        recording = Recording()
        swallowing = nil
        return deactivate(.interrupted)
    }

    /// A modifier went down or up. Its key code says which side; the group's flag says whether any of that group
    /// is still down (clear: both sides are up), and the side bits, when the keyboard sends them, say which.
    /// Without them it toggles that side, checked against the flag.
    mutating func flagsChanged(code: UInt16, flags: UInt64) -> [Output] {
        let before = held
        if code == 63 {
            set(.fn, flags & Self.fnFlag != 0)
        } else if let side = Self.sides[code] {
            if flags & side.flag == 0 {
                held.subtract([side.mine, side.other])
            } else if flags & (side.myBit | side.otherBit) != 0 {
                set(side.mine, flags & side.myBit != 0)
                set(side.other, flags & side.otherBit != 0)
            } else {
                set(side.mine, !held.contains(side.mine))
                // The flag says one of the two is down.
                if !held.contains(side.mine), !held.contains(side.other) { held.insert(side.mine) }
            }
        } else {
            return []  // Caps Lock unmapped, or a key we don't know: not ours
        }
        return modifiersChanged(from: before)
    }

    /// A key went down (or repeated) or up. True: swallow it.
    mutating func key(code: UInt16, down: Bool, isRepeat: Bool, flags: UInt64) -> (Bool, [Output]) {
        if code == Self.f18, capsIsF18 {
            // Caps Lock, held like a modifier. Never typed: an F18 would put escape codes into a terminal.
            let swallow = recording == nil
            guard !isRepeat else { return (swallow, []) }
            let before = held
            set(.capsLock, down)
            return (swallow, held == before ? [] : modifiersChanged(from: before))
        }
        // Missed key-ups: a modifier the event's flags say is up, is up (handy-keys does the same).
        var outputs = reconcile(flags: flags)
        if recording != nil { return (false, outputs + recordKey(code: code, down: down, isRepeat: isRepeat)) }
        if code == swallowing {
            if !down {
                swallowing = nil
                outputs += deactivate(.up)
            }
            return (true, outputs)
        }
        guard down else { return (false, outputs) }
        if let shortcut, shortcut.key == code, !active, !isRepeat, shortcut.matches(held) {
            active = true
            swallowing = code
            return (true, outputs + [.down])
        }
        if active {
            if shortcut?.key == nil { spoiled = true }
            outputs += deactivate(.interrupted)
        }
        return (false, outputs)
    }

    /// The tap was off for a moment. Modifiers the system says are up are up; the shortcut's key, or Caps Lock,
    /// can't be checked, so a hold that needs one ends (better than listening on after a missed key-up).
    mutating func lostTrack(flags: UInt64) -> [Output] {
        var outputs = reconcile(flags: flags)
        if let shortcut, shortcut.key != nil || shortcut.usesCapsLock {
            held.remove(.capsLock)
            swallowing = nil
            outputs += deactivate(.up)
        }
        return outputs
    }

    /// The safety timer's check: still active, and the system agrees the modifiers it needs are down.
    mutating func checkStillDown(flags: UInt64) -> Bool {
        guard active, let shortcut else { return false }
        for (group, flag) in Self.groupFlags where !shortcut.modifiers.isDisjoint(with: group) && flags & flag == 0 {
            held.subtract(group)
            active = false
            spoiled = false
            return false
        }
        if shortcut.modifiers.contains(.fn), flags & Self.fnFlag == 0 {
            held.remove(.fn)
            active = false
            return false
        }
        return true
    }

    // MARK: rules

    private mutating func modifiersChanged(from before: Modifiers) -> [Output] {
        let pressed = !held.subtracting(before).isEmpty
        if recording != nil { return recordModifiers() }
        guard let shortcut else { return [] }
        if spoiled, held.isDisjoint(with: shortcut.modifiers) { spoiled = false }
        let match = shortcut.matches(held)
        if active, !match {
            // One of its keys let go: done. Another modifier added: a different shortcut, not dictation.
            if pressed, shortcut.key == nil { spoiled = true }
            return deactivate(pressed ? .interrupted : .up)
        }
        if !active, match, pressed, !spoiled, shortcut.key == nil {
            active = true
            return [.down]
        }
        return []
    }

    private mutating func reconcile(flags: UInt64) -> [Output] {
        let before = held
        for (group, flag) in Self.groupFlags where flags & flag == 0 { held.subtract(group) }
        if flags & Self.fnFlag == 0 { held.remove(.fn) }
        guard held != before, let shortcut, active, !shortcut.matches(held) else { return [] }
        return deactivate(.up)
    }

    private mutating func deactivate(_ how: Output) -> [Output] {
        guard active else { return [] }
        active = false
        return [how]
    }

    private mutating func set(_ m: Modifiers, _ on: Bool) {
        if on { held.insert(m) } else { held.remove(m) }
    }

    // MARK: recording

    /// Modifiers alone: recorded once they're all let go, with no key in between.
    private mutating func recordModifiers() -> [Output] {
        guard var rec = recording else { return [] }
        rec.peak.formUnion(held)
        recording = rec
        guard held.isEmpty, !rec.peak.isEmpty else { return [] }
        recording = nil
        return [.recorded(.shortcut(DictationShortcut(modifiers: Self.recorded(rec.peak, alone: true))))]
    }

    /// A key with whatever modifiers are held. Esc alone cancels.
    private mutating func recordKey(code: UInt16, down: Bool, isRepeat: Bool) -> [Output] {
        guard down, !isRepeat else { return [] }
        if code == Self.esc, held.isEmpty {
            recording = nil
            return [.recorded(.cancelled)]
        }
        let shortcut = DictationShortcut(modifiers: Self.recorded(held, alone: false), key: code)
        if let problem = shortcut.problem { return [.recorded(.refused(problem))] }
        recording = nil
        return [.recorded(.shortcut(shortcut))]
    }

    /// One modifier held alone keeps its side ("Right ⌘": left ⌘ is for shortcuts). Anything else takes either side
    /// of each group, the way "⌃⌥ Space" reads.
    static func recorded(_ held: Modifiers, alone: Bool) -> Modifiers {
        let sided = held.subtracting([.fn, .capsLock])
        if alone, held == sided, sided.rawValue.nonzeroBitCount == 1 { return held }
        var out = held
        for (group, _) in groupFlags where !held.isDisjoint(with: group) { out.formUnion(group) }
        return out
    }
}
