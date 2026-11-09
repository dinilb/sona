import AppKit
import NotesKit
import SonaEngine
import SwiftUI

// Sona: the menu bar icon, the window (Now, past conversations, Settings), hold-to-dictate and the always-on
// notes, in one process. AppKit runs the app, so nothing opens by itself at login and the Dock icon only shows
// while the window is open; the window's content is SwiftUI.
//
// Test runs never reach the app delegate: no window, no menu bar icon, no Dock icon, no focus, no fn takeover,
// no launch agent, never the real mic, and only with SONA_HOME set to a test home.
//   LIVE_SNAPSHOT=/path.png [LIVE_SNAPSHOT_VIEW=now|day|day:YYYY-MM-DD|conversation|dictations|settings|about|firstrun|pill|copied]:
//     draws that view with the test home's notes (ImageRenderer, no window), writes the PNG and exits. `day` is the
//     newest day's list, `conversation` its newest one. LIVE_SNAPSHOT_DARK=1 draws it as if macOS were in Dark mode
//     (it should look the same: the app is always light).
//   LIVE_FILE=x.wav: the app's pipeline (live transcript, always-on notes) headless, on that file then silence,
//     until SIGTERM.
//   SONA_KEY_PROBE=<shortcut>|record: only the dictation key monitor, printing what it sees (KeyProbe), until SIGTERM.

if let probe = ProcessInfo.processInfo.environment["SONA_KEY_PROBE"], !probe.isEmpty {
    guard Paths.isTestHome else {
        FileHandle.standardError.write(Data("SONA_KEY_PROBE needs SONA_HOME set to a test folder.\n".utf8))
        exit(2)
    }
    MainActor.assumeIsolated { KeyProbe.run(probe) }
}

if TestRun.isOn {
    guard Paths.isTestHome else {
        FileHandle.standardError.write(Data("LIVE_FILE and LIVE_SNAPSHOT runs need SONA_HOME set to a test folder.\n".utf8))
        exit(2)
    }
    MainActor.assumeIsolated {
        // If anything makes the app object, it can never show in the Dock or take focus.
        NSApplication.shared.setActivationPolicy(.prohibited)
        if let path = TestRun.snapshot {
            Snapshot.render(to: path, view: ProcessInfo.processInfo.environment["LIVE_SNAPSHOT_VIEW"] ?? "now")
            exit(0)
        }
        Headless.run()
    }
}

MainActor.assumeIsolated {
    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate
    app.setActivationPolicy(.accessory)
    app.appearance = NSAppearance(named: .aqua)  // always light, even in Dark mode
    withExtendedLifetime(delegate) { app.run() }
}

/// Draws one view of the window into a PNG with ImageRenderer: no window, no app run loop.
@MainActor
enum Snapshot {
    static func render(to path: String, view: String) {
        let settings = Settings.load()
        let store = NoteStore(root: settings.conversationsURL)
        let names = store.names()
        let newest = names.first.flatMap { try? store.read(url: settings.conversationsURL.appendingPathComponent($0.id + ".md")) }
        let day = view == "day" ? names.first?.day : view.hasPrefix("day:") ? String(view.dropFirst(4)) : nil
        let selection: SidebarItem =
            switch view {
            case "settings": .settings
            case "dictations": .dictations
            case "about": .about
            case "conversation": newest.map { .conversation($0.id) } ?? .now
            default: day.map { .day($0) } ?? .now
            }
        let model = AppModel(
            previewOf: newest, names: names, selection: selection,
            day: day.map { Array(store.conversations(from: $0, to: $0).reversed()) }, firstRun: view == "firstrun")
        // Regression check for the preview model: toggling every month header saves settings and updates the mic.
        if ProcessInfo.processInfo.environment["LIVE_SNAPSHOT_TOGGLE_MONTHS"] != nil {
            for month in DayGroups(days: names.map(\.day), today: model.library.today).months { model.update { $0.openMonths[month.id] = !month.startsOpen } }
            Log.note("snapshot toggled months without touching the mic")
        }
        // The first run as a new Mac sees it; Settings is taller than the window, so it's drawn whole.
        let content: AnyView =
            view == "firstrun"
            ? AnyView(FirstRunView(model: model, mic: .notDetermined, trusted: false).fixedSize())
            : view == "pill"
                ? AnyView(DictationPill(dictation: model.dictation).frame(width: DictationPill.size.width, height: DictationPill.size.height))
                : view == "copied"
                    ? AnyView(CopiedToast(text: "Copied to clipboard").frame(width: DictationPill.size.width, height: DictationPill.size.height))
                    : AnyView(RootView(model: model).frame(width: 960, height: view == "settings" ? 900 : 620))
        let root = content
            .environment(\.staticRender, true)
            .environment(\.colorScheme, ProcessInfo.processInfo.environment["LIVE_SNAPSHOT_DARK"] == nil ? .light : .dark)
        let renderer = ImageRenderer(content: root)
        renderer.scale = 2
        guard let image = renderer.cgImage,
            let png = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])
        else {
            Log.note("snapshot failed: nothing rendered")
            return
        }
        do {
            try png.write(to: URL(fileURLWithPath: path))
        } catch {
            Log.note("snapshot failed: \(Log.describe(error))")
            return
        }
        // Proof for the log: no window of ours exists, on screen or off.
        let windows = (CGWindowListCopyWindowInfo([.optionAll], kCGNullWindowID) as? [[String: Any]] ?? [])
            .filter { ($0[kCGWindowOwnerPID as String] as? Int32) == getpid() }
        Log.note("snapshot saved (\(view), \(image.width)x\(image.height)); windows of this process: \(windows.count)")
    }
}

/// The app's pipeline without the app: the model on a plain run loop. No NSApplication run, no window, no menu bar
/// icon; SIGTERM saves the open conversation and exits.
@MainActor
enum Headless {
    static func run() -> Never {
        guard let lock = AppLock.acquire() else {
            Log.note("another copy is already running, quitting")
            exit(0)
        }
        Paths.tightenSupport()
        Models.goOffline()
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"
        Log.note("launched \(version) headless (test run, support: \(Paths.support.path))")
        let model = AppModel()
        model.start()
        var sources: [DispatchSourceSignal] = []
        for sig in [SIGTERM, SIGINT, SIGHUP] {
            signal(sig, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: sig, queue: .main)
            source.setEventHandler {
                MainActor.assumeIsolated {
                    Log.note("signal \(sig), saving and exiting")
                    Task {
                        await model.finish()
                        exit(0)
                    }
                }
            }
            source.resume()
            sources.append(source)
        }
        withExtendedLifetime((lock, model, sources)) {
            while true { RunLoop.main.run() }
        }
        exit(0)
    }
}
