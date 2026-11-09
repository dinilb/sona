import AppKit
import CoreGraphics
import LiveCore
import NotesKit

/// `SONA_KEY_PROBE=<shortcut>`: only the key monitor, for testing it with posted events. No mic, models, window or
/// settings file. It prints each shortcut down, up and interruption with its time and how late it reached the main
/// thread, and when the safety check stops agreeing it's held. The shortcut is written as in settings.json
/// (`rightCommand`, `{"modifiers":["control","option"]}`, `{"modifiers":["capsLock"],"key":0}`); `record` records
/// one shortcut instead. Posted events marked with `mark` (eventSourceUserData) that get past the monitor are
/// printed too: what other apps see, so a swallowed key shows up as missing. Caps Lock in the shortcut is remapped
/// while it runs. It quits by itself after `lifetime` seconds (or once a shortcut is recorded), giving Caps Lock
/// back, so a test that forgets to stop it can't leave the keyboard watched; SIGTERM or SIGINT quit sooner.
@MainActor
enum KeyProbe {
    static let mark: Int64 = 0x50A7
    nonisolated static let isOn = !(ProcessInfo.processInfo.environment["SONA_KEY_PROBE"] ?? "").isEmpty
    static let lifetime = 20.0

    static func run(_ spec: String) -> Never {
        setvbuf(stdout, nil, _IOLBF, 0)
        Log.echoToStderr = true
        CapsLockKey.defaults = UserDefaults(suiteName: "com.dinilb.sona.keyprobe") ?? .standard
        let keys = KeyMonitor.shared
        var held = false
        keys.onEvent = { event in
            switch event {
            case .down(let at):
                held = true
                say("down at \(fmt(at)) (\(ms(hostNow() - at)) ms to the main thread)")
            case .up(let at):
                held = false
                say("up at \(fmt(at)) (\(ms(hostNow() - at)) ms to the main thread)")
            case .interrupted:
                held = false
                say("interrupted")
            }
        }
        if spec == "record" {
            CapsLockKey.takeOver()
            record()
        } else {
            let json = spec.hasPrefix("{") ? spec : "\"\(spec)\""
            guard let shortcut = try? JSONDecoder().decode(DictationShortcut.self, from: Data(json.utf8)) else {
                say("can't read the shortcut \(spec)")
                exit(2)
            }
            if shortcut.usesCapsLock { CapsLockKey.takeOver() }
            keys.watch(shortcut)
            say("watching \(shortcut.title)")
        }
        // The safety timer's question, as dictation asks it.
        Timer.scheduledTimer(withTimeInterval: 0.2, repeats: true) { _ in
            MainActor.assumeIsolated {
                if held, !keys.isStillDown() {
                    held = false
                    say("safety check: not held any more")
                }
            }
        }
        let seen = watchDownstream()
        DispatchQueue.main.asyncAfter(deadline: .now() + lifetime) { quit("time's up") }
        var sources: [DispatchSourceSignal] = []
        for sig in [SIGTERM, SIGINT] {
            signal(sig, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: sig, queue: .main)
            source.setEventHandler { MainActor.assumeIsolated { quit("signal \(sig)") } }
            source.resume()
            sources.append(source)
        }
        withExtendedLifetime((sources, seen)) {
            while true { RunLoop.main.run() }
        }
        exit(0)
    }

    private static func quit(_ why: String) {
        CapsLockKey.restore()
        say("bye (\(why))")
        exit(0)
    }

    private static func record() {
        say("press a shortcut")
        KeyMonitor.shared.record { result in
            switch result {
            case .shortcut(let shortcut):
                let json = (try? JSONEncoder().encode(shortcut)).map { String(decoding: $0, as: UTF8.self) } ?? "?"
                say("recorded \(shortcut.title) \(json)")
                quit("recorded")
            case .refused(let why): say("refused: \(why)")
            case .cancelled: quit("cancelled")
            }
        }
    }

    /// A listen-only tap behind everyone else's, printing marked events that got through.
    private static func watchDownstream() -> CFMachPort? {
        let mask: CGEventMask = (1 << CGEventType.keyDown.rawValue) | (1 << CGEventType.keyUp.rawValue) | (1 << CGEventType.flagsChanged.rawValue)
        let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap, place: .tailAppendEventTap, options: .listenOnly, eventsOfInterest: mask,
            callback: { _, type, event, _ in
                if event.getIntegerValueField(.eventSourceUserData) == KeyProbe.mark {
                    let code = event.getIntegerValueField(.keyboardEventKeycode)
                    let kind = type == .keyDown ? "keyDown" : type == .keyUp ? "keyUp" : "flagsChanged"
                    let again = event.getIntegerValueField(.keyboardEventAutorepeat) != 0 ? " (repeat)" : ""
                    print("    passed on: \(kind) \(code)\(again) flags 0x\(String(event.flags.rawValue, radix: 16))")
                }
                return Unmanaged.passUnretained(event)
            }, userInfo: nil)
        guard let tap else {
            say("no downstream tap")
            return nil
        }
        CFRunLoopAddSource(CFRunLoopGetMain(), CFMachPortCreateRunLoopSource(nil, tap, 0), .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        return tap
    }

    private static func say(_ line: String) { print("[\(fmt(hostNow()))] \(line)") }
    private static func fmt(_ t: Double) -> String { String(format: "%.3f", t) }
    private static func ms(_ s: Double) -> String { String(format: "%.1f", s * 1000) }
}
