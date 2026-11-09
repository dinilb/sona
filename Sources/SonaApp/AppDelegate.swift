import AppKit
import NotesKit
import SonaEngine
import SwiftUI

/// The app's shell: the single-copy lock, the menu bar icon and its menu, the window (and the Dock icon only
/// while it's open), quitting and signals. Real launches only: test runs never get here (see main.swift).
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate, NSWindowDelegate {
    private var lock: AppLock?
    private var model: AppModel!
    private var statusItem: NSStatusItem?
    private let statusMenu = NSMenu()
    private var window: NSWindow?
    /// The first-run screen's own small window, until Start.
    private var firstRun: NSWindow?
    private var quitting = false
    private var signalSources: [DispatchSourceSignal] = []

    private var atLogin = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        // First, while the launch's Apple event (the open-application one, sent after willFinishLaunching) is still
        // the current one: an alert or anything else that handles events can replace it.
        atLogin = LoginItem.launchedAtLogin
        // Run from the disk image (or a translocated copy): Open at login and the AI setup line would point at a
        // path that disappears. Ask for the move first.
        let path = Bundle.main.bundlePath
        if path.contains("/AppTranslocation/") || path.hasPrefix("/Volumes/") {
            let alert = NSAlert()
            alert.messageText = "Move Sona to Applications first"
            alert.informativeText = "Drag Sona into your Applications folder, then open it from there."
            alert.addButton(withTitle: "Quit")
            NSApp.activate(ignoringOtherApps: true)
            alert.runModal()
            exit(0)
        }
        lock = LoginItem.takeLock()  // may exit: only one copy ever listens
        Paths.tightenSupport()  // folders and files older versions left readable by other accounts
        Models.goOffline()  // only model downloads may ever use the network
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"
        Log.note("launched \(version)\(atLogin ? " at login" : "") (support: \(Paths.support.path))")
        LoginItem.removeOldAgent()
        watchSignals()
        model = AppModel()
        setUpMainMenu()
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusMenu.delegate = self
        item.menu = statusMenu
        statusItem = item
        trackStatus()
        model.start()
        // Opened by someone (not at login): show the window. The first-run screen shows either way.
        if !atLogin || !model.settings.onboarded { showWindow(.now) }
    }

    /// Opening the app again (Finder, Spotlight, the Dock, a second copy started) shows the window.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showWindow()
        return false
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    // MARK: window

    private func showWindow(_ item: SidebarItem? = nil) {
        guard model.settings.onboarded else { return showFirstRun() }
        if let item { model.selection = item }
        if window == nil {
            let w = NSWindow(contentViewController: NSHostingController(rootView: RootView(model: model)))
            w.title = "Sona"
            w.styleMask = [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView]
            w.usePaperLook()
            w.isReleasedWhenClosed = false
            w.isRestorable = false
            w.setContentSize(NSSize(width: 960, height: 620))
            w.delegate = self
            w.center()
            w.setFrameAutosaveName("Sona")
            window = w
        }
        model.windowOpen = true
        NSApp.setActivationPolicy(.regular)
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        model.windowVisible = true  // coming to the front; an occlusion change says otherwise if it's covered
        LayoutCheck.soon()
    }

    /// Minimised, covered by other windows or on another Space: Now stops taking new lines until it can be seen.
    func windowDidChangeOcclusionState(_ notification: Notification) {
        guard let w = notification.object as? NSWindow, w === window else { return }
        model.windowVisible = w.occlusionState.contains(.visible)
    }

    /// The first-run screen, in a small window of its own. Closing it leaves the app in the menu bar, not listening.
    private func showFirstRun() {
        if firstRun == nil {
            let view = FirstRunView(model: model) { [weak self] in
                guard let self else { return }
                self.showWindow(.now)
                self.firstRun?.close()
            }
            let w = NSWindow(contentViewController: NSHostingController(rootView: view))
            w.title = "Sona"
            w.styleMask = [.titled, .closable]
            w.usePaperLook()
            w.isReleasedWhenClosed = false
            w.isRestorable = false
            w.delegate = self
            w.center()
            firstRun = w
        }
        NSApp.setActivationPolicy(.regular)
        firstRun?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    /// Closing a window never quits; the Dock icon goes with the last one. The views are freed until it's opened again.
    func windowWillClose(_ notification: Notification) {
        guard let closing = notification.object as? NSWindow else { return }
        if closing === window {
            model.windowOpen = false
            model.windowVisible = false
            window = nil
        } else if closing === firstRun {
            firstRun = nil
        } else {
            return
        }
        closing.delegate = nil
        if window == nil, firstRun == nil { NSApp.setActivationPolicy(.accessory) }
    }

    private func setUpMainMenu() {
        let main = NSMenu()
        let appItem = NSMenuItem()
        let appMenu = NSMenu()
        appMenu.addItem(action("About Sona", #selector(openAbout)))
        appMenu.addItem(.separator())
        appMenu.addItem(action("Settings...", #selector(openSettings), key: ","))
        appMenu.addItem(.separator())
        appMenu.addItem(NSMenuItem(title: "Hide Sona", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h"))
        appMenu.addItem(NSMenuItem(title: "Quit Sona", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        appItem.submenu = appMenu
        main.addItem(appItem)
        let editItem = NSMenuItem()
        let edit = NSMenu(title: "Edit")
        edit.addItem(NSMenuItem(title: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x"))
        edit.addItem(NSMenuItem(title: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c"))
        edit.addItem(NSMenuItem(title: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v"))
        edit.addItem(NSMenuItem(title: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a"))
        editItem.submenu = edit
        main.addItem(editItem)
        let windowItem = NSMenuItem()
        let windowMenu = NSMenu(title: "Window")
        windowMenu.addItem(NSMenuItem(title: "Close", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w"))
        windowMenu.addItem(NSMenuItem(title: "Minimize", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m"))
        windowItem.submenu = windowMenu
        main.addItem(windowItem)
        NSApp.mainMenu = main
        NSApp.windowsMenu = windowMenu
    }

    // MARK: menu bar

    /// Redraws the icon whenever what it shows changes.
    private func trackStatus() {
        withObservationTracking {
            _ = model.menuIcon
            _ = model.statusLine
        } onChange: { [weak self] in
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    self?.refreshStatusItem()
                    self?.trackStatus()
                }
            }
        }
        refreshStatusItem()
    }

    private func refreshStatusItem() {
        guard let button = statusItem?.button else { return }
        // The image is shared (one per state), so VoiceOver's label goes on the button, not on it.
        button.image = MenuBarIcon.image(model.menuIcon)
        button.setAccessibilityLabel("Sona: \(model.statusLine)")
        button.toolTip = "Sona: \(model.statusLine)"
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let status = NSMenuItem(title: model.statusLine, action: nil, keyEquivalent: "")
        status.isEnabled = false
        menu.addItem(status)
        if model.liveLoadFailed { menu.addItem(action("Try the Download Again", #selector(retryDownload))) }
        menu.addItem(action("Open Sona", #selector(openWindow)))
        menu.addItem(.separator())
        if model.isPaused {
            menu.addItem(action("Resume", #selector(resume)))
        } else {
            menu.addItem(action("Pause for 1 Hour", #selector(pauseHour)))
            menu.addItem(action("Pause Until Tomorrow", #selector(pauseTomorrow)))
        }
        if model.settings.onboarded {
            let delete = NSMenuItem(title: "Delete the Last", action: nil, keyEquivalent: "")
            let choices = NSMenu()
            for minutes in DeleteRecent.choices {
                let item = action("\(minutes) Minutes…", #selector(deleteRecent(_:)))
                item.tag = minutes
                choices.addItem(item)
            }
            delete.submenu = choices
            menu.addItem(delete)
        }
        // The safety net when a paste lands in the wrong place, and a way to send a bad dictation to the bench.
        if model.dictation.lastText != nil {
            menu.addItem(.separator())
            menu.addItem(action("Copy Last Dictation", #selector(copyLastDictation)))
            menu.addItem(action("Save Last Dictation for Debugging", #selector(saveLastDictation)))
        }
        menu.addItem(.separator())
        menu.addItem(action("Quit Sona", #selector(quit), key: "q"))
    }

    private func action(_ title: String, _ selector: Selector, key: String = "") -> NSMenuItem {
        let item = NSMenuItem(title: title, action: selector, keyEquivalent: key)
        item.target = self
        return item
    }

    @objc private func retryDownload() { model.loadLive() }

    @objc private func pauseHour() { model.pause(until: Date().addingTimeInterval(3600)) }

    /// Until 6 in the morning tomorrow.
    @objc private func pauseTomorrow() {
        let cal = Calendar.current
        let tomorrow = cal.date(byAdding: .day, value: 1, to: cal.startOfDay(for: Date())) ?? Date().addingTimeInterval(86_400)
        model.pause(until: cal.date(bySettingHour: 6, minute: 0, second: 0, of: tomorrow) ?? tomorrow)
    }

    @objc private func resume() { model.resume() }
    @objc private func openWindow() { showWindow() }
    @objc private func openSettings() { showWindow(.settings) }
    @objc private func openAbout() { showWindow(.about) }
    @objc private func deleteRecent(_ sender: NSMenuItem) { DeleteRecent.ask(sender.tag, model: model) }

    @objc private func copyLastDictation() {
        guard let text = model.dictation.lastText else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    /// Writes it to the support folder's Debug folder and shows it in Finder.
    @objc private func saveLastDictation() {
        do {
            NSWorkspace.shared.activateFileViewerSelecting([try model.dictation.saveLastForDebugging()])
        } catch {
            Log.note("couldn't save the last dictation: \(Log.describe(error))")
        }
    }
    @objc private func quit() { NSApp.terminate(nil) }

    // MARK: quitting

    /// Your own Quit asks first, so a stray Cmd-Q doesn't end a day of listening. Logout and shutdown don't ask.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        if quitting { return .terminateNow }
        let isAppleEvent = NSAppleEventManager.shared().currentAppleEvent != nil
        // Before the first run is done nothing is listening, so there's nothing to warn about.
        if !isAppleEvent, model.settings.onboarded {
            NSApp.activate(ignoringOtherApps: true)
            let alert = NSAlert()
            alert.messageText = "Stop listening?"
            alert.informativeText =
                "Sona won't hear anything, and dictation won't work, until you open it again. To stop for a while, "
                + "use Pause instead. The current conversation is saved and gets transcribed next time."
            alert.addButton(withTitle: "Quit")
            alert.addButton(withTitle: "Cancel")
            guard alert.runModal() == .alertFirstButtonReturn else { return .terminateCancel }
        }
        Log.note("quitting (\(isAppleEvent ? "apple event" : "menu"))")
        quitting = true
        Task {
            await model.finish()
            FnKey.restore()
            CapsLockKey.restore()
            sender.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }

    /// A plain `kill` (or logout) still saves the open conversation to the spool and gives the fn key and Caps Lock back.
    private func watchSignals() {
        for sig in [SIGTERM, SIGINT, SIGHUP] {
            signal(sig, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: sig, queue: .main)
            source.setEventHandler { [weak self] in
                MainActor.assumeIsolated {
                    Log.note("signal \(sig), saving and exiting")
                    FnKey.restore()
                    CapsLockKey.restore()
                    Task {
                        await self?.model.finish()
                        exit(0)
                    }
                    DispatchQueue.main.asyncAfter(deadline: .now() + 5) { exit(0) }
                }
            }
            source.resume()
            signalSources.append(source)
        }
    }
}

/// A scroll view moved below the title bar and also scrolled down by it draws its content that much lower than where
/// it takes clicks (the sidebar did). Only a real window shows it, so the open windows are checked a moment after the
/// window opens and after the main pane changes (a walk over a few hundred views), and it's logged once.
@MainActor
enum LayoutCheck {
    private static var logged = false

    static func soon() {
        guard !logged else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
            guard !logged else { return }
            for window in NSApp.windows where window.isVisible {
                if let points = offset(in: window.contentView) {
                    logged = true
                    Log.note("layout problem: a scroll view is drawn \(points) pt below where it takes clicks")
                    return
                }
            }
        }
    }

    /// How far below its click areas a scroll view in `view` is drawn, if one is.
    static func offset(in view: NSView?) -> Int? {
        guard let view else { return nil }
        if let scroll = view as? NSScrollView, scroll.contentInsets.top > 0 {
            let clip = scroll.contentView.frame
            if (scroll.isFlipped ? clip.minY : scroll.bounds.height - clip.maxY) >= scroll.contentInsets.top {
                return Int(scroll.contentInsets.top)
            }
        }
        return view.subviews.lazy.compactMap { offset(in: $0) }.first
    }
}
