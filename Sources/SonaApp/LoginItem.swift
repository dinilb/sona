import AppKit
import NotesKit
import ServiceManagement

/// "Open at login" is the system's own login item for the app (SMAppService.mainApp): no background agent of
/// our own. If Sona quits or crashes it stays down until the next login or until it's opened again,
/// and the menu bar icon going away is the honest signal that it isn't listening.
@MainActor
enum LoginItem {
    /// Turns the login item on or off. Returns a message to show, if any.
    @discardableResult
    static func apply(_ on: Bool) -> String? {
        if Paths.isTestHome { return nil }  // test runs never register anything
        let app = SMAppService.mainApp
        do {
            if on, app.status != .enabled {
                try app.register()
                Log.note("open at login: on")
            } else if !on, app.status == .enabled {
                try app.unregister()
                Log.note("open at login: off")
            }
        } catch {
            Log.note("open at login change failed: \(Log.describe(error))")
            return "Couldn't change Open at login: \(error.localizedDescription)"
        }
        if app.status == .requiresApproval {
            return "Allow Sona in System Settings > General > Login Items."
        }
        return nil
    }

    /// Builds before 30 Oct 2026 kept the app alive with a launchd agent (`com.dinilb.sona.keepalive`). Once a
    /// build's signature changed, launchd refused to start it and retried forever. Remove it for good.
    /// (The agent's plist stays in the bundle only so it can be unregistered here.)
    static func removeOldAgent() {
        if Paths.isTestHome { return }
        let agent = SMAppService.agent(plistName: "com.dinilb.sona.keepalive.plist")
        guard agent.status != .notRegistered, agent.status != .notFound else { return }
        do {
            try agent.unregister()
            Log.note("removed the old keep-alive agent")
        } catch {
            Log.note("couldn't remove the old keep-alive agent: \(Log.describe(error))")
        }
    }

    /// True when the system opened the app at login (then it starts quietly, without its window).
    static var launchedAtLogin: Bool {
        guard let event = NSAppleEventManager.shared().currentAppleEvent else { return false }
        return event.eventID == kAEOpenApplication
            && event.paramDescriptor(forKeyword: keyAEPropData)?.enumCodeValue == keyAELaunchedAsLogInItem
    }

    /// One copy only. If another is running, it's opened again the way Finder would (LaunchServices sends it a reopen,
    /// so it shows its window) and this one quits. With no other copy of the app (the command line tool holds the
    /// lock), it just quits. Without the lock (its file can't be opened), it runs only if no other copy is running.
    static func takeLock() -> AppLock {
        let lock = AppLock.acquire()
        if let lock, lock.isHeld { return lock }
        let running = NSRunningApplication.runningApplications(withBundleIdentifier: Bundle.main.bundleIdentifier ?? "")
            .first { $0.processIdentifier != getpid() }
        if let lock, running == nil {
            Log.note("running without the lock: no other copy is running")
            return lock
        }
        guard let url = running?.bundleURL else {
            Log.note("another copy (or the command line tool) is already running, quitting")
            exit(0)
        }
        Log.note("another copy is already running, showing it instead")
        let done = DispatchSemaphore(value: 0)
        // Called on a concurrent queue, not the main thread (which waits here).
        NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration()) { @Sendable _, error in
            if let error { Log.note("couldn't show the running copy: \(Log.describe(error))") }
            done.signal()
        }
        _ = done.wait(timeout: .now() + 5)
        exit(0)
    }
}
