import AppKit
import NotesKit

/// "Agent command" mode: while Command is held (alone, for at least half a second), what's said is meant for an AI
/// agent. It only listens, through a global flags-changed monitor (no event tap, no key swallowed, and no key
/// contents read), and saves each hold with `CommandHolds`.
@MainActor
final class CommandKey {
    /// The hold going on now, if any.
    private(set) var heldSince: Date?
    private var monitor: Any?
    /// Called when a hold starts or ends, so the window and the feed can mark lines.
    var onChange: () -> Void = {}
    /// Command tapped twice quickly, alone: start or stop capturing speech to paste.
    var onDoubleTap: () -> Void = {}
    private var keyMonitor: Any?
    private var otherKeyDuringPress = false
    private var lastTapEnd: Date?
    static let maxTap = 0.3
    static let tapGap = 0.45

    func start() {
        guard monitor == nil, KeyMonitor.mayTouchKeyboard else { return }
        monitor = NSEvent.addGlobalMonitorForEvents(matching: .flagsChanged) { [weak self] event in
            let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            MainActor.assumeIsolated { self?.flags(flags) }
        }
        if monitor == nil { Log.note("agent command: couldn't watch the Command key") }
        // A key pressed during the tap makes it a shortcut (⌘C ⌘C), not a double tap. Needs Input Monitoring; without
        // it this never fires and only the timing is used.
        keyMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] _ in
            MainActor.assumeIsolated { self?.otherKeyDuringPress = true }
        }
    }

    func stop() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        monitor = nil
        keyMonitor = nil
        press(false)
    }

    private func flags(_ flags: NSEvent.ModifierFlags) {
        // Command alone: with Shift, Option or Control it's a shortcut (⌘⇧4), not a command to an agent.
        press(flags.contains(.command) && flags.isDisjoint(with: [.shift, .option, .control, .function]))
    }

    /// Down or up at this moment (also called by `TestCommand`).
    func press(_ down: Bool, at time: Date = Date()) {
        if down, heldSince == nil {
            heldSince = time
            otherKeyDuringPress = false
            onChange()
        } else if !down, let start = heldSince {
            heldSince = nil
            let length = time.timeIntervalSince(start)
            if CommandHolds.append(start: start, end: time) {
                Log.note("agent command saved")
                lastTapEnd = nil
            } else if length <= Self.maxTap, !otherKeyDuringPress {
                if let last = lastTapEnd, start.timeIntervalSince(last) <= Self.tapGap {
                    lastTapEnd = nil
                    onDoubleTap()
                } else {
                    lastTapEnd = time
                }
            } else {
                lastTapEnd = nil
            }
            onChange()
        }
    }
}
