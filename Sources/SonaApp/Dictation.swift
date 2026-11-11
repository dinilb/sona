import AppKit
import ApplicationServices
import Carbon.HIToolbox
import LiveCore
import NotesKit
import SonaEngine
import SwiftUI

/// Hold the dictation shortcut (fn, or one set in Settings) to dictate into any app. While the key is down, the live
/// transcript's words since it went down show in a slim one-line pill at the bottom of the screen. On release, the hold's
/// own audio is transcribed once more, whole, with the notes model (`clips`, when it's downloaded; else the live
/// words are used), and the text is pasted into whatever has focus (your clipboard is put back). Nothing is pasted
/// before every word up to the release is in. With always-on recording off, the mic only opens while the key is
/// held (`onHold`).
@MainActor
@Observable
final class Dictation {
    enum Phase { case idle, listening, finishing }

    private(set) var phase: Phase = .idle
    /// The live words heard since the key went down.
    private(set) var text = ""
    /// Accessibility is granted (needed to see the key system-wide and to paste).
    private(set) var trusted = AXIsProcessTrusted()
    /// A short message in the pill instead of words ("Paused", "Copied to clipboard").
    private(set) var notice: String?
    /// The notice is that the words were left on the clipboard instead of pasted: it's drawn as its own small toast.
    private(set) var noticeCopied = false
    /// The mic is delivering audio for this hold. Until it is (it was closed, or is reopening) the pill says "Mic
    /// starting...", so nobody talks into a mic that isn't on yet.
    private(set) var micReady = true
    /// Let go, and the text still isn't ready after `spinnerAfter`: the pill's dot turns into a spinner.
    private(set) var waiting = false
    /// The last dictation's text, for the menu's Copy Last Dictation. Only in memory: gone on quit.
    private(set) var lastText: String?

    /// The setting is on.
    @ObservationIgnored private(set) var enabled = true
    @ObservationIgnored private(set) var key = DictationShortcut.fn
    /// Why dictation can't start right now ("Paused"), or nil.
    @ObservationIgnored var blocked: () -> String? = { nil }
    /// The key went down (true) or the dictation ended (false): with always-on off, the mic is opened for it.
    @ObservationIgnored var onHold: (Bool) -> Void = { _ in }
    /// Text was pasted (not when it was only copied, for a password field).
    @ObservationIgnored var onPaste: (String) -> Void = { _ in }
    /// The words list ("Sonar" → "Sona").
    @ObservationIgnored var fixer = WordFixer.none
    /// Is the key still held? Asked every 0.2 s during a hold, so a missed key-up never leaves it listening. The key
    /// monitor answers (`install`), or a test run does.
    @ObservationIgnored var isKeyStillDown: () -> Bool = { false }
    /// Transcribes the hold's own audio on release. Nil (the notes model isn't downloaded, or didn't load): the live
    /// words are pasted.
    @ObservationIgnored var clips: ClipTranscriber?
    /// Test runs: each finished dictation goes here instead of being pasted (no key events, no clipboard).
    @ObservationIgnored var testOutput: ((Report) -> Void)?
    /// Test runs never show the pill (no windows).
    @ObservationIgnored var showsPill = true

    /// A finished dictation, for `testOutput` and "Save Last Dictation for Debugging". Times are `hostNow()` seconds.
    struct Report {
        var text: String
        var outcome: String
        var pressed: Double
        var released: Double
        /// When the text was ready (pasted).
        var done: Double
        var micWasOn: Bool
        var live: String
        var liveDone: Double?
        var clip: String?
        var clipDone: Double?
        /// It was quiet just before the release, so the clip was cut there (no `tail`).
        var noTail = false
        /// Test runs: the clip pass again with other tails, and without levelling (name → text, ready at).
        var extra: [(name: String, text: String, done: Double)] = []
        /// The hold's audio, from `debugLead` before the press to `debugLead / 3` after the release, and where the
        /// press and release fall in it (seconds).
        var audio: [Float] = []
        var audioPress = 0.0
        var audioRelease = 0.0
    }

    @ObservationIgnored private(set) var relay: RelaySource?
    @ObservationIgnored private(set) var session: LiveSession?

    @ObservationIgnored private var installed = false
    @ObservationIgnored private var holding = false
    @ObservationIgnored private var tokens: [LiveToken] = []
    /// Whole words only: the current word is in or out as a whole, decided by its first piece's time.
    @ObservationIgnored private var includeWord = false
    @ObservationIgnored private var spaceBefore = false
    /// The live words of the last couple of seconds, kept while idle too: the first word can be out before the press
    /// is handled, and words said just before the press can belong to it.
    @ObservationIgnored private var history: [LiveToken] = []
    /// Checks the key is really still down (a missed key-up must never leave it listening) and caps a hold.
    @ObservationIgnored private var keyTimer: Timer?
    /// Pressed again while the last one was still pasting.
    @ObservationIgnored private var pendingPress = false
    /// Session seconds: the press, where its live words start, the release, and the first word said just before the
    /// press that runs straight into it.
    @ObservationIgnored private var press = 0.0
    @ObservationIgnored private var from = 0.0
    @ObservationIgnored private var until: Double?
    @ObservationIgnored private var joinedStart: Double?
    @ObservationIgnored private var pressedAt = 0.0
    @ObservationIgnored private var releasedAt = 0.0
    @ObservationIgnored private var micWasOn = true
    /// Bumped by every press, so a late callback from an earlier hold does nothing.
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var liveDone: Double?
    @ObservationIgnored private var clip: (text: String?, done: Double)?
    /// Where the clip is cut: `tail` after the release, or the release itself when it was already quiet then.
    @ObservationIgnored private var clipEnd = 0.0
    @ObservationIgnored private var tailSkipped = false
    /// What has focus, read on another thread while the last audio comes in (`readFocus`); nil until it's back.
    @ObservationIgnored private var focusRead: FocusedText.Read?
    @ObservationIgnored private var focusPending = false
    /// When the press of `lastText` was (`hostNow()`), so "delete the last N minutes" can forget it.
    @ObservationIgnored private var lastTextPressed = 0.0
    @ObservationIgnored private var panel: NSPanel?
    /// Where the last dictation was pasted and when (`hostNow()`): when Accessibility can't see the caret, a paste soon
    /// after one into the same app follows it with a space.
    @ObservationIgnored private var lastPaste: (pid: pid_t, at: Double)?
    /// For the log line: how many live words the pill had at the release, and whether its place had to be moved onto a
    /// screen (a pill on no screen is invisible).
    @ObservationIgnored private var liveWordsAtRelease = 0
    @ObservationIgnored private var pillMoved = false
    /// For the log line too: words that came out during the hold but were timed before its start or after its end.
    /// More than a stray one means the live times and the hold's times disagree (an empty pill with the words heard).
    @ObservationIgnored private var outsideBefore = 0
    @ObservationIgnored private var outsideAfter = 0
    /// The last dictation, for "Save Last Dictation for Debugging" (memory only, until the next one or quit).
    @ObservationIgnored private(set) var last: Report?

    /// Tokens up to this long after the release still belong to it: the model emits a word's full stop
    /// about 0.1 s after the sound ends.
    static let trailing = 0.12
    /// Live words from this long before the press count: people start talking as they press.
    static let preRoll = 0.2
    /// Words up to this long before the press count too, if they run straight into the dictated ones (no pause:
    /// less than `joinGap` from one word's last piece to the next word).
    static let joinWindow = 0.5
    static let joinGap = 0.4
    /// Real audio after the release that still belongs to it (a last word that runs past the key), before the live
    /// engine is flushed and the clip is cut. Test runs can set it (`LIVE_DICTATE_TAIL`).
    static let tail = ProcessInfo.processInfo.environment["LIVE_DICTATE_TAIL"].flatMap(Double.init) ?? 0.15
    /// Quiet for this long before the release (below the voice gate's silence floor): no word runs past the key, so
    /// there's no tail to wait for.
    static let quietBefore = 0.1
    static let quietFloor = VoiceGate.Config().floor
    /// The old clipboard comes back this long after a paste, if the words are still on it. Long enough for a slow or
    /// busy app to read the words first: one that reads late would paste the old clipboard instead.
    static let restoreAfter = 3.0
    /// After the release, the longest it waits for the text; then it pastes what it has and says so.
    static let maxWait = 8.0
    /// A paste this quick shows no spinner.
    static let spinnerAfter = 0.25
    /// A paste into the same app this soon after the last one follows it, when the caret can't be read.
    static let sameAppWindow = 120.0
    /// A paste where Accessibility couldn't tell if a text box has focus: no app reading the words this soon after
    /// means it went nowhere, and the pill says they're on the clipboard.
    static let takenWithin = 0.6
    /// How long "Copied to clipboard" stays.
    static let copiedFor = 3.0
    /// The hold's audio kept for debugging starts this long before the press.
    static let debugLead = 1.5

    /// Holds shorter than this with nothing heard are taps, not dictation.
    private let minimumHold = 0.25
    /// The longest hold; past it, it pastes what it has.
    private let maxHold = 120.0
    /// Double-tap ⌘ started it: it listens with no key held, until the next tap of ⌘ (or the dictation key).
    @ObservationIgnored private(set) var latched = false
    /// A latched dictation stops by itself after this long, in case the tap to end it never comes.
    private let maxLatched = 600.0

    /// The session words come from. Dictation only runs while one is attached.
    func attach(_ session: LiveSession, relay: RelaySource) {
        if phase != .idle { cancel() }
        self.session = session
        self.relay = relay
    }

    /// The session ended (stopped, failed, restarted): forget it, and drop any hold that used it.
    func detach(_ session: LiveSession) {
        guard self.session === session else { return }
        if phase != .idle { cancel() }
        self.session = nil
        relay = nil
    }

    /// The setting or the shortcut changed. fn alone, or Caps Lock, is only taken over while it's the shortcut,
    /// dictation is on and Accessibility is granted (or the key would do nothing anywhere); otherwise it's given back.
    func configure(enabled: Bool, key: DictationShortcut) {
        if phase != .idle, !enabled || key != self.key { cancel() }
        self.enabled = enabled
        self.key = key
        guard installed else { return }
        let on = enabled && trusted
        if on, key == .fn { FnKey.takeOver() } else { FnKey.restore() }
        if on, key.usesCapsLock { CapsLockKey.takeOver() } else { CapsLockKey.restore() }
        KeyMonitor.shared.watch(on ? key : nil)
    }

    /// Starts watching the keys (not in test runs). `prompt`: macOS asks for Accessibility if it's missing.
    func install(prompt: Bool = true) {
        guard !installed else { return }
        installed = true
        trusted = AXIsProcessTrustedWithOptions(["AXTrustedCheckOptionPrompt": enabled && prompt] as CFDictionary)
        NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated {
                FnKey.restore()
                CapsLockKey.restore()
            }
        }
        // Sleep, screen lock or a user switch mid-hold: drop it rather than keep listening.
        let workspace = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.willSleepNotification, NSWorkspace.screensDidSleepNotification, NSWorkspace.sessionDidResignActiveNotification] {
            workspace.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { if self?.phase != .idle { self?.cancel() } }
            }
        }
        // Modifiers are also used for shortcuts (⌘Tab...) the key monitor never sees: switching apps mid-hold
        // means it wasn't dictation, and nothing gets pasted into the app that just came forward.
        workspace.addObserver(forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.key != .fn, self.phase == .listening else { return }
                self.cancel()
            }
        }
        let keys = KeyMonitor.shared
        keys.onEvent = { [weak self] event in
            switch event {
            case .down(let at): self?.keyDown(at: at)
            case .up(let at): self?.keyUp(at: at)
            case .interrupted: self?.interrupted()
            }
        }
        isKeyStillDown = { keys.isStillDown() }
        configure(enabled: enabled, key: key)
        // Granting access in System Settings doesn't notify; check now and then until it's on.
        if !trusted {
            Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] timer in
                let done = MainActor.assumeIsolated { () -> Bool in
                    guard let self else { return true }
                    self.trusted = AXIsProcessTrusted()
                    if self.trusted { self.configure(enabled: self.enabled, key: self.key) }
                    return self.trusted
                }
                if done { timer.invalidate() }
            }
        }
    }

    /// Tokens from the live transcript (session time), in order. Kept for a couple of seconds even while idle; during
    /// a hold they're collected into its words.
    func feed(_ new: [LiveToken]) {
        history.append(contentsOf: new)
        if let newest = history.last?.start, let first = history.first?.start, newest - first > 4 {
            history.removeAll { $0.start < newest - 2 }
        }
        guard phase != .idle else { return }
        collect(new, counting: true)
    }

    /// A word is kept or dropped whole, by when its first piece was heard, so neither end of the hold chops a word in
    /// half. A dictation never starts with punctuation: the last sentence's full stop comes out a moment after its
    /// sound, inside this hold's window.
    /// `counting`: words that just came out (not the history read at the press) and fall outside the hold are counted
    /// for the log line.
    private func collect(_ new: [LiveToken], counting: Bool = false) {
        var added = false
        for token in new {
            let bare = token.text.trimmingCharacters(in: .whitespaces)
            // Numbers come as a bare space, then the digits: the space belongs to the next word.
            if bare.isEmpty {
                spaceBefore = true
                continue
            }
            if tokens.isEmpty, bare.allSatisfy({ $0.isPunctuation }) {
                spaceBefore = false
                continue
            }
            if token.text.hasPrefix(" ") || spaceBefore || tokens.isEmpty && !includeWord {
                includeWord = token.start >= from && token.start <= (until ?? .infinity) + Self.trailing
                if counting, !includeWord, !bare.allSatisfy({ $0.isPunctuation }) {
                    if token.start < from { outsideBefore += 1 } else { outsideAfter += 1 }
                }
                if includeWord, tokens.isEmpty {
                    let joined = joinedWords(before: token.start)
                    joinedStart = joined.first?.start
                    tokens = joined
                }
            }
            if includeWord {
                tokens.append(spaceBefore && !token.text.hasPrefix(" ") ? LiveToken(text: " " + token.text, start: token.start) : token)
                added = true
            }
            spaceBefore = false
        }
        if added { text = fixer.apply(Self.clean(tokens.map(\.text).joined())) }
    }

    /// Words said just before the press (up to `joinWindow`) that run straight into the first dictated word at
    /// `first`, with no pause between: someone who starts talking a moment before the key is down.
    private func joinedWords(before first: Double) -> [LiveToken] {
        // A mic that was closed has no "just before".
        guard micWasOn else { return [] }
        let earlier = history.prefix { $0.start < first }
        var out: [LiveToken] = []
        var word: [LiveToken] = []
        var next = first
        // Backwards, a word at a time (a word starts at a piece with a space, or after a bare space).
        for token in earlier.reversed() {
            let bare = token.text.trimmingCharacters(in: .whitespaces)
            if bare.isEmpty {
                if let start = word.first { word[0] = LiveToken(text: " " + start.text, start: start.start) }
            } else {
                word.insert(token, at: 0)
            }
            guard let start = word.first, start.text.hasPrefix(" ") else { continue }
            // A word that ends a sentence or a clause ("Right, got it.") is followed by a pause: it's not this one's.
            guard let lastPiece = word.last, next - lastPiece.start < Self.joinGap, start.start >= press - Self.joinWindow,
                !word.contains(where: { $0.text.contains { ".?!,;:".contains($0) } })
            else { break }
            out.insert(contentsOf: word, at: 0)
            next = start.start
            word = []
        }
        return out
    }

    // MARK: the key, from whatever watches it

    /// The dictation key went down at `host` (`hostNow()` seconds, the clock of `ProcessInfo.systemUptime` and of an
    /// NSEvent's `timestamp`).
    func keyDown(at host: Double) {
        switch phase {
        case .idle: begin(at: Self.sane(host))
        case .finishing: pendingPress = true
        case .listening: break
        }
    }

    /// The dictation key came up at `host` (`hostNow()` seconds).
    func keyUp(at host: Double) {
        switch phase {
        case .listening: release(at: Self.sane(host))
        case .finishing: pendingPress = false
        case .idle: break
        }
    }

    /// A key time from another clock (seconds off, or in the future) would put the hold in the wrong place: now instead.
    private static func sane(_ host: Double) -> Double {
        let now = hostNow()
        return host <= now && now - host < 2 ? host : now
    }

    /// Something else happened during the hold (another key, a shortcut, an app switch): it wasn't dictation.
    func interrupted() {
        if phase == .listening, !latched { cancel("another key") }
    }

    /// Double-tap ⌘: start dictating without holding anything; called again (one tap of ⌘), stop and paste.
    func toggleLatched() {
        switch phase {
        case .idle:
            latched = true
            begin(at: hostNow())
            if phase != .listening { latched = false }
        case .listening where latched: release(at: hostNow())
        default: break
        }
    }

    /// Listening with no key held (double-tap ⌘), so one tap of ⌘ ends it.
    var isLatched: Bool { phase == .listening && latched }

    private func begin(at host: Double) {
        guard enabled else { return }
        if let why = blocked() { return flash(why) }
        guard session != nil, let relay else { return flash("Not listening") }
        generation += 1
        // Live audio: from a little before the press (people start talking as they press). A closed mic opens
        // now, so everything from its first sample on counts (nothing older is from this press).
        let flowing = relay.isFlowing
        press = flowing ? relay.clock.seconds(atHost: host) ?? relay.endSeconds : relay.endSeconds
        from = flowing ? press - Self.preRoll : press
        until = nil
        joinedStart = nil
        pressedAt = host
        micWasOn = flowing
        liveDone = nil
        clip = nil
        tailSkipped = false
        focusRead = nil
        focusPending = false
        tokens = []
        includeWord = false
        spaceBefore = false
        text = ""
        notice = nil
        noticeCopied = false
        waiting = false
        micReady = flowing
        liveWordsAtRelease = 0
        pillMoved = false
        outsideBefore = 0
        outsideAfter = 0
        phase = .listening
        relay.keep(from: press - Self.debugLead)
        hold(true)
        showPanel()
        // Words already out that belong to it (the main thread was busy, or they ran straight into it).
        collect(history)
        keyTimer = Timer.scheduledTimer(withTimeInterval: 0.2, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.phase == .listening else { return }
                let keyUp = !self.latched && !self.isKeyStillDown()
                if keyUp || hostNow() - self.pressedAt > (self.latched ? self.maxLatched : self.maxHold) { self.release(at: hostNow()) }
            }
        }
        if !flowing { waitForMic(generation) }
    }

    /// "Mic starting..." until the first audio comes.
    private func waitForMic(_ gen: Int) {
        guard gen == generation, phase != .idle else { return }
        if relay?.isFlowing == true {
            micReady = true
            return
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.03) { [weak self] in self?.waitForMic(gen) }
    }

    private func release(at host: Double) {
        keyTimer?.invalidate()
        keyTimer = nil
        liveWordsAtRelease = DictationText.wordCount(text)
        if host - pressedAt < minimumHold, tokens.isEmpty { return cancel("a tap") }
        guard let relay else { return cancel("no live transcript") }
        until = relay.isFlowing ? relay.clock.seconds(atHost: host) ?? relay.endSeconds : relay.endSeconds
        releasedAt = host
        phase = .finishing
        let gen = generation
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.spinnerAfter) { [weak self] in
            guard let self, gen == self.generation, self.phase == .finishing else { return }
            self.waiting = true
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.maxWait) { [weak self] in
            guard let self, gen == self.generation, self.phase == .finishing else { return }
            self.finish(cutShort: true)
        }
        // Test runs paste nothing, so they don't ask what has focus.
        if testOutput == nil { readFocus(gen) }
        waitForTail(gen)
    }

    /// What has focus (a text box? a password field? what's before the caret?), read on another thread while the last
    /// audio comes in and is transcribed, so it adds nothing to the wait. With secure input on (a password being
    /// typed somewhere), the text before the caret isn't read.
    private func readFocus(_ gen: Int) {
        focusPending = true
        let caret = !IsSecureEventInputEnabled()
        DispatchQueue.global(qos: .userInteractive).async { [weak self] in
            let read = FocusedText.read(caret: caret)
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self, gen == self.generation else { return }
                    self.focusRead = read
                    self.focusPending = false
                    self.decide()
                }
            }
        }
    }

    /// The last word can run past the key: wait for `tail` of real audio after the release (unless the mic stopped),
    /// then give the live engine silence for its look-ahead and cut the clip. If it was already quiet just before the
    /// release, nothing runs past it: no tail, the clip is cut as soon as the audio up to the release is in.
    private func waitForTail(_ gen: Int) {
        guard gen == generation, phase == .finishing, let relay, let until else { return }
        clipEnd = until + Self.tail
        if relay.isFlowing {
            let end = relay.endSeconds
            let quiet = end >= until
                && DictationText.endsQuiet(relay.audio(from: until - Self.quietBefore, to: end), floor: Self.quietFloor)
            if end < until + Self.tail, !quiet {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.01) { [weak self] in self?.waitForTail(gen) }
                return
            }
            tailSkipped = end < until + Self.tail
            clipEnd = min(end, until + Self.tail)
        }
        // Don't wait for real audio to fill the model's look-ahead: give it silence now.
        session?.flush()
        waitForLastWord(gen)
        transcribeClip(gen)
    }

    /// The live words are all out once the engine has decoded everything up to the release (with the flush, about
    /// one engine step). Polls every 15 ms; never gives up early (`maxWait` is the only limit).
    private func waitForLastWord(_ gen: Int) {
        guard gen == generation, phase == .finishing, let until else { return }
        // If the sentence's full stop is already out, there's nothing more to wait for.
        let ended = text.last.map { ".?!,".contains($0) } ?? false
        if session?.hasDecoded(through: until + (ended ? 0 : Self.trailing)) ?? true {
            // Tokens arrive through the main queue right after the engine step that decoded them.
            DispatchQueue.main.async { [weak self] in
                guard let self, gen == self.generation else { return }
                self.liveDone = hostNow()
                self.decide()
            }
        } else {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.015) { [weak self] in self?.waitForLastWord(gen) }
        }
    }

    /// The hold's own audio, whole, through the notes model: from just before its first word (one said just before
    /// the press included) to `clipEnd`.
    private func transcribeClip(_ gen: Int) {
        guard let clips, let relay else { return }
        let audio = relay.audio(from: min(from, (joinedStart ?? from) - 0.15), to: clipEnd)
        Task { [weak self] in
            let text = try? await clips.transcribe(audio)
            guard let self, gen == self.generation else { return }
            self.clip = (text, hostNow())
            self.decide()
        }
    }

    /// Pastes as soon as the text is final: the clip's, else (no notes model, or the clip pass failed or heard
    /// nothing) the live words once they're all out. Test runs wait for both, to compare them. A paste also waits for
    /// the focus read (`readFocus`), which is nearly always back first.
    private func decide() {
        guard phase == .finishing, !focusPending else { return }
        let clipText = clip?.text.map { fixer.apply(Self.clean($0)) } ?? ""
        let clipPending = clips != nil && clip == nil
        if testOutput != nil, clipPending || liveDone == nil { return }
        if !clipText.isEmpty || !clipPending && liveDone != nil { finish(cutShort: false) }
    }

    private func finish(cutShort: Bool) {
        guard phase == .finishing else { return }
        let clipText = clip?.text.map { fixer.apply(Self.clean($0)) } ?? ""
        let fromClip = !clipText.isEmpty
        let result = fromClip ? clipText : text
        let now = hostNow()
        // When the text was ready: the clip's, or the live words', whichever was used.
        let ready = fromClip ? clip?.done ?? now : liveDone ?? now
        let again = pendingPress
        // Is a text box focused, and is it a password field? Read during the wait (`readFocus`), or now if that isn't
        // back (cut short); the caret for the spacing comes from the same read. Test runs paste nothing and don't ask.
        let pasting = testOutput == nil && !result.isEmpty
        let secureInput = pasting && IsSecureEventInputEnabled()
        let focus = pasting ? focusRead ?? FocusedText.read(caret: !secureInput) : nil
        // A password field (Accessibility says so, or secure input is on): never pasted into.
        let secure = secureInput || focus?.secure == true
        let target = secure ? nil : focus.map { DictationText.pasteTarget(for: $0.focus) }
        var outcome = "pasted"
        if result.isEmpty {
            outcome = "nothing heard"
        } else if secure {
            outcome = "copied to the clipboard (a password field)"
        } else if target == .noTextBox {
            outcome = "copied to the clipboard, no text box selected"
        } else {
            if cutShort { outcome = "cut short, pasted what it had" }
            if target == .unknown { outcome += ", kept on the clipboard (couldn't tell if a text box is selected)" }
        }
        let report = Report(
            text: result, outcome: outcome, pressed: pressedAt, released: releasedAt, done: ready, micWasOn: micWasOn,
            live: text, liveDone: liveDone, clip: clip.map { $0.text ?? "" }, clipDone: clip?.done, noTail: tailSkipped)
        // Why a pill can be short of words: the live engine hadn't got to the release yet (its words were late), or
        // words came out timed outside the hold.
        var live = ""
        if liveDone == nil, let until, let decoded = session?.decodedThrough {
            live += String(format: ", live words not all out (engine %.1f s behind the release)", max(0, until - decoded))
        }
        if outsideBefore + outsideAfter > 0 { live += ", \(outsideBefore) live words timed before the hold and \(outsideAfter) after it" }
        Log.note(
            String(format: "dictation: held %.1f s, mic %@ at the press, text ready %.2f s after the release (%@%@), %d words, %d live words in the pill (%d by the release)%@%@, %@",
                releasedAt - pressedAt, micWasOn ? "on" : "starting", ready - releasedAt,
                fromClip ? "whole clip" : clips == nil ? "live words, no clip model" : clip == nil ? "live words" : "live words, clip pass failed",
                tailSkipped ? ", quiet at the release so no tail" : "",
                result.split(separator: " ").count, DictationText.wordCount(text), liveWordsAtRelease, live,
                pillMoved ? ", pill moved onto a screen" : "", outcome))
        if !result.isEmpty {
            lastText = result
            lastTextPressed = pressedAt
        }
        reset()
        keepAudio(report)
        if let testOutput {
            if let relay, let until, let clips {
                // The clip pass again with other tails, to pick the shortest that keeps the last word.
                let start = min(from, (joinedStart ?? from) - 0.15), released = releasedAt, base = report
                Task {
                    var report = base
                    while relay.endSeconds < until + 0.3 { try? await Task.sleep(nanoseconds: 10_000_000) }
                    let audio = relay.audio(from: start, to: until + 0.3)
                    for tail in [0.0, 0.15, 0.3] {
                        let t0 = hostNow()
                        let cut = Array(audio.prefix(max(0, audio.count - Int((0.3 - tail) * AudioClock.sampleRate))))
                        let text = (try? await clips.transcribe(cut)) ?? ""
                        report.extra.append(("clip_tail\(Int(tail * 100))", fixer.apply(Self.clean(text)), released + tail + hostNow() - t0))
                    }
                    testOutput(report)
                }
            } else {
                testOutput(report)
            }
        } else if secure {
            // A password field (or Terminal's secure keyboard entry): don't type into it, leave it to the user.
            // Marked concealed, like a password manager's copy, and cleared after a minute if untouched.
            Self.copyOnly(result, clearAfter: 60, concealed: true)
            flash("Copied to clipboard (password field)", for: Self.copiedFor, copied: true)
        } else if let focus, let target {
            switch target {
            case .noTextBox:
                // A paste would land nowhere and the clipboard would be put back over the words: leave them on it.
                Self.copyOnly(result, clearAfter: nil)
                flash("Copied to clipboard", for: Self.copiedFor, copied: true)
            case .textBox:
                pasteAtCaret(result, after: focus.caret, restoreClipboard: true)
                onPaste(result)
            case .unknown:
                // If the paste went nowhere, the words are still on the clipboard. They're only handed over when an
                // app reads them, so if none does, the pill can say where they are.
                let watch = PasteWatch()
                pasteAtCaret(result, after: focus.caret, restoreClipboard: false, watch: watch)
                onPaste(result)
                let gen = generation
                DispatchQueue.main.asyncAfter(deadline: .now() + Self.takenWithin) { [weak self] in
                    guard !watch.taken else { return }
                    watch.settle()
                    guard let self, gen == self.generation else { return }
                    self.flash("Copied to clipboard", for: Self.copiedFor, copied: true)
                }
            }
        }
        if cutShort, !secure, target != .noTextBox { flash("Cut short") }
        // Pressed again while this one was pasting, and still held: start the next one.
        if again, isKeyStillDown() { begin(at: hostNow()) }
    }

    /// The hold's audio for "Save Last Dictation for Debugging": what's kept now, and the rest of the lead-out a
    /// moment later (unless another dictation has started). Then the relay goes back to keeping only a few seconds.
    private func keepAudio(_ report: Report) {
        last = report
        guard let relay, let until else { return }
        let end = until + Self.debugLead / 3
        let gen = generation
        DispatchQueue.main.asyncAfter(deadline: .now() + max(0, end - relay.endSeconds) + 0.05) { [weak self] in
            guard let self, gen == self.generation else { return }
            // Forgotten meanwhile ("delete the last N minutes"): nothing to fill in, but the relay still lets go.
            guard var last = self.last else { return relay.keep(from: nil) }
            let start = self.press - Self.debugLead
            last.audio = relay.audio(from: start, to: end)
            // As much as was kept: it may start later than asked.
            let begun = end - Double(last.audio.count) / AudioClock.sampleRate
            last.audioPress = self.press - begun
            last.audioRelease = until - begun
            self.last = last
            relay.keep(from: nil)
        }
    }

    /// "Delete the last N minutes": the last dictation kept in memory (its text for Copy Last Dictation, its text and
    /// audio for Save Last Dictation for Debugging) goes if it was pressed from `cut` on.
    func forget(from cut: Date) {
        let host = hostNow() - Date().timeIntervalSince(cut)
        if let last, last.pressed >= host { self.last = nil }
        if lastText != nil, lastTextPressed >= host { lastText = nil }
    }

    /// Pastes `text`, with a space in front when it would run into what's before the caret ("the lid.Yeah"). The
    /// focused field said what's there (`caret`, through Accessibility); if it couldn't (Electron apps, some terminals),
    /// a paste into the same app within `sameAppWindow` of the last one gets the space. Never for a password field.
    private func pasteAtCaret(_ text: String, after caret: FocusedText.Caret, restoreClipboard: Bool, watch: PasteWatch? = nil) {
        let app = NSWorkspace.shared.frontmostApplication?.processIdentifier
        let recently = lastPaste.map { $0.pid == app && hostNow() - $0.at < Self.sameAppWindow } ?? false
        let space: Bool
        switch caret {
        case .start: space = false
        case .after(let character): space = DictationText.leadingSpace(before: character, sameAppRecently: recently)
        case .unknown: space = DictationText.leadingSpace(before: nil, sameAppRecently: recently)
        }
        Self.paste(space ? " " + text : text, restoreClipboard: restoreClipboard, watch: watch)
        lastPaste = app.map { (pid: $0, at: hostNow()) }
    }

    /// Puts the words on the clipboard and nothing else. Marked transient so clipboard managers don't keep them
    /// (and concealed, for a password field); cleared after `clearAfter` seconds if nothing else has replaced them, or
    /// never.
    private static func copyOnly(_ text: String, clearAfter seconds: Double?, concealed: Bool = false) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.writeObjects([clipboardItem(text, concealed: concealed)])
        guard let seconds else { return }
        let ours = pasteboard.changeCount
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds) {
            if pasteboard.changeCount == ours { pasteboard.clearContents() }
        }
    }

    /// Ends a hold without pasting anything, and says why in the log.
    private func cancel(_ why: String = "cancelled") {
        if phase != .idle {
            Log.note(String(format: "dictation: held %.1f s, mic %@ at the press, cancelled (%@)", hostNow() - pressedAt, micWasOn ? "on" : "starting", why))
            relay?.keep(from: nil)
        }
        reset()
    }

    private func reset() {
        keyTimer?.invalidate()
        keyTimer = nil
        phase = .idle
        latched = false
        pendingPress = false
        tokens = []
        waiting = false
        micReady = true
        panel?.orderOut(nil)
        panel = nil
        hold(false)
    }

    private func hold(_ on: Bool) {
        guard on != holding else { return }
        holding = on
        session?.holdOpen(on)
        onHold(on)
    }

    /// A short note in the pill (capture mode's start and end).
    func announce(_ message: String, for seconds: Double = 1.5) { flash(message, for: seconds) }

    /// A note in the pill for a moment (no listening behind it), then it fades out. `copied`: the words were left on
    /// the clipboard instead of pasted, shown as a small toast whose clipboard pops in.
    private func flash(_ message: String, for seconds: Double = 1.2, copied: Bool = false) {
        guard phase == .idle else { return }
        notice = message
        noticeCopied = copied
        showPanel()
        let shown = panel
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds) { [weak self] in
            guard let self, self.phase == .idle, self.panel === shown else { return }
            guard let shown else {
                self.notice = nil
                self.noticeCopied = false
                return
            }
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.3
                shown.animator().alphaValue = 0
            } completionHandler: { [weak self] in
                MainActor.assumeIsolated {
                    shown.orderOut(nil)
                    guard let self, self.phase == .idle, self.panel === shown else { return }
                    self.notice = nil
                    self.noticeCopied = false
                    self.panel = nil
                }
            }
        }
    }

    /// Parakeet already punctuates and capitalises; this drops fillers, punctuation left at the start (from what was
    /// said before), and tidies spaces.
    static func clean(_ raw: String) -> String {
        var s = raw.replacingOccurrences(of: #"(?i)\b(um+|uh+|uhm|erm|hmm+)\b[,.]?\s*"#, with: "", options: .regularExpression)
        s = s.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
        s = s.replacingOccurrences(of: #"^[\s.,;:!?…]+"#, with: "", options: .regularExpression).trimmingCharacters(in: .whitespaces)
        if let first = s.first, first.isLowercase { s = first.uppercased() + s.dropFirst() }
        return s
    }

    /// The words as one clipboard item, with its markers on the same item, written in one go (set one after the other,
    /// a clipboard manager could read the words before the marker is there): transient, so clipboard managers don't
    /// keep them, and concealed too for a password field. With a `watch`, the words themselves are only handed over
    /// when an app reads them.
    fileprivate static func clipboardItem(_ text: String, concealed: Bool, watch: PasteWatch? = nil) -> NSPasteboardItem {
        let item = NSPasteboardItem()
        if let watch, item.setDataProvider(watch, forTypes: [.string]) {
            watch.arm(text)
        } else {
            item.setString(text, forType: .string)
        }
        item.setData(Data(), forType: NSPasteboard.PasteboardType("org.nspasteboard.TransientType"))
        if concealed { item.setData(Data(), forType: NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType")) }
        return item
    }

    /// Puts the text on the clipboard, presses Cmd+V in the focused app, then puts the old clipboard back. Not when
    /// `restoreClipboard` is off: the paste may have gone nowhere, and then the words are still on the clipboard.
    /// A password manager's copy (concealed) is never put back: the clipboard is left empty instead, as its own timer
    /// would have left it, rather than bring a password back where clipboard history can see it.
    /// `watch` (only without the restore): it learns whether an app read the words.
    static func paste(_ text: String, restoreClipboard: Bool = true, watch: PasteWatch? = nil) {
        let pasteboard = NSPasteboard.general
        let items = restoreClipboard ? pasteboard.pasteboardItems ?? [] : []
        let secret = items.contains { DictationText.isSecret(clipboardTypes: $0.types.map(\.rawValue)) }
        // Only the common, cheap types: asking for every type can make the source app render big promised
        // data (huge images, files) on the spot. And the managers' markers, so what comes back is still marked.
        let keep: Set<NSPasteboard.PasteboardType> = [.string, .rtf, .rtfd, .html, .png, .tiff, .fileURL, .URL]
        let saved: [NSPasteboardItem] =
            secret
            ? []
            : items.map { item in
                let copy = NSPasteboardItem()
                for type in item.types where keep.contains(type) || DictationText.isClipboardMarker(type.rawValue) {
                    if let data = item.data(forType: type) { copy.setData(data, forType: type) }
                }
                return copy
            }.filter { !$0.types.isEmpty }
        pasteboard.clearContents()
        pasteboard.writeObjects([clipboardItem(text, concealed: false, watch: watch)])
        let ours = pasteboard.changeCount
        watch?.written(changeCount: ours)

        let source = CGEventSource(stateID: .combinedSessionState)
        let v = vKey()
        for keyDown in [true, false] {
            let event = CGEvent(keyboardEventSource: source, virtualKey: v, keyDown: keyDown)
            event?.flags = .maskCommand
            event?.post(tap: .cghidEventTap)
        }
        guard restoreClipboard else { return }
        // Slow apps (Electron, VMs, one that's busy) read the clipboard late; only restore if nothing else has
        // replaced the words.
        DispatchQueue.main.asyncAfter(deadline: .now() + restoreAfter) {
            guard pasteboard.changeCount == ours else { return }
            pasteboard.clearContents()
            if !saved.isEmpty { pasteboard.writeObjects(saved) }
        }
    }

    /// The key that makes ⌘V in the current keyboard layout (on AZERTY or Dvorak it isn't QWERTY's V; with
    /// "Dvorak - QWERTY ⌘" it is, which is why the ⌘ is held for the lookup). A layout without a "v" (Cyrillic, say)
    /// falls back to the Latin one the system uses for shortcuts, then to 9 (QWERTY).
    static func vKey() -> CGKeyCode {
        let sources = [TISCopyCurrentKeyboardLayoutInputSource(), TISCopyCurrentASCIICapableKeyboardLayoutInputSource()]
        for case let source? in sources.map({ $0?.takeRetainedValue() }) {
            guard let pointer = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData) else { continue }
            let data = Unmanaged<CFData>.fromOpaque(pointer).takeUnretainedValue() as Data
            let found = data.withUnsafeBytes { raw -> CGKeyCode? in
                guard let layout = raw.baseAddress?.assumingMemoryBound(to: UCKeyboardLayout.self) else { return nil }
                for code in 0..<UInt16(128) {
                    var dead: UInt32 = 0
                    var length = 0
                    var chars = [UniChar](repeating: 0, count: 4)
                    let status = UCKeyTranslate(
                        layout, code, UInt16(kUCKeyActionDisplay), UInt32((cmdKey >> 8) & 0xFF), UInt32(LMGetKbdType()),
                        OptionBits(kUCKeyTranslateNoDeadKeysBit), &dead, chars.count, &length, &chars)
                    if status == noErr, length == 1, chars[0] == UniChar(118) { return CGKeyCode(code) }  // "v"
                }
                return nil
            }
            if let found { return found }
        }
        return 9
    }

    /// Where the pill goes: the bottom centre of the screen the mouse is on, just above the Dock. Right after a wake or
    /// a display change the screen list, or a screen's visible area, can be stale, and a pill that isn't on any screen
    /// you can see is invisible: so a place that isn't fully on a current screen is dropped for the main screen, then
    /// the first one, then (as a last resort) the full frame of each.
    private static func pillFrame(size: NSSize) -> (frame: NSRect, moved: Bool) {
        let screens = NSScreen.screens
        func place(_ area: NSRect) -> NSRect {
            NSRect(x: area.midX - size.width / 2, y: area.minY + pillMargin, width: size.width, height: size.height)
        }
        let mouse = NSEvent.mouseLocation
        let candidates = [screens.first { NSMouseInRect(mouse, $0.frame, false) }, NSScreen.main, screens.first]
            .compactMap { $0 }
            .flatMap { [place($0.visibleFrame), place($0.frame)] }
        let onScreen = { (frame: NSRect) in screens.contains { $0.frame.contains(frame) } }
        if let found = candidates.firstIndex(where: onScreen) { return (candidates[found], found > 0) }
        // Nothing lands on a current screen: the first choice anyway (a guess on the main display if there are no
        // screens at all).
        return (candidates.first ?? place(NSRect(x: 0, y: 0, width: 1440, height: 900)), true)
    }

    /// Space between the pill and the bottom of the usable screen (above the Dock).
    private static let pillMargin: CGFloat = 20

    // A fresh panel each time: a reused one can silently stop drawing after sleep or a display change.
    private func showPanel() {
        guard showsPill else { return }
        // One at a time: a note still fading out goes now.
        panel?.orderOut(nil)
        let (frame, moved) = Self.pillFrame(size: DictationPill.size)
        pillMoved = moved
        let panel = NSPanel(contentRect: frame, styleMask: [.nonactivatingPanel, .borderless], backing: .buffered, defer: false)
        panel.isFloatingPanel = true
        panel.level = .statusBar
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        panel.ignoresMouseEvents = true
        panel.hidesOnDeactivate = false
        panel.contentView = NSHostingView(rootView: DictationPill(dictation: self))
        panel.orderFrontRegardless()
        self.panel = panel
    }
}

/// The pill: a slim line at the bottom of the screen, a dot (or a spinner) and the latest words, so the rest of the
/// screen stays readable.
struct DictationPill: View {
    let dictation: Dictation
    @State private var pulse = false

    /// The panel. The pill fills it less `edge` on each side.
    static let size = NSSize(width: 524, height: 42)
    private static let edge: CGFloat = 2
    private static let inset: CGFloat = 16
    private static let dot: CGFloat = 9
    private static let gap: CGFloat = 10
    private static let fontSize: CGFloat = 14
    /// The width left for the words.
    private static var textWidth: CGFloat { size.width - 2 * (edge + inset) - dot - gap }

    var body: some View {
        if dictation.noticeCopied, let notice = dictation.notice {
            CopiedToast(text: notice)
        } else {
            pill
        }
    }

    private var pill: some View {
        HStack(spacing: Self.gap) {
            // Let go and still working on it: a small spinner where the dot was, the words staying as they are.
            if dictation.waiting {
                ProgressView()
                    .controlSize(.small)
                    .frame(width: Self.dot, height: Self.dot)
            } else {
                Circle()
                    .fill(dictation.phase == .finishing || !dictation.micReady ? Theme.grey.opacity(0.5) : Theme.ink)
                    .frame(width: Self.dot, height: Self.dot)
                    .scaleEffect(pulse ? 1.25 : 0.85)
                    .animation(.easeInOut(duration: 0.6).repeatForever(autoreverses: true), value: pulse)
                    .onAppear { pulse = true }
            }
            // One line. The words are already cut to fit (`latest`); cutting the front is the fallback if the font
            // measures a little differently, so the newest words never go.
            Text(shown)
                .font(.system(size: Self.fontSize))
                .foregroundStyle(dictation.text.isEmpty ? Theme.grey : Theme.ink)
                .lineLimit(1)
                .truncationMode(.head)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, Self.inset)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Capsule(style: .continuous).fill(Theme.paper))
        .overlay(Capsule(style: .continuous).strokeBorder(Theme.hairline))
        .padding(Self.edge)
        .environment(\.colorScheme, .light)
    }

    private var shown: String {
        if let notice = dictation.notice { return notice }
        if !dictation.text.isEmpty { return Self.latest(dictation.text) }
        if !dictation.micReady { return "Mic starting..." }
        return dictation.phase == .finishing ? "…" : "listening…"
    }

    /// The end of the words that fits on the line, cut at a word with "…" in front, so it scrolls as you talk.
    static func latest(_ words: String) -> String {
        let attributes: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: fontSize)]
        // A little short of the real width, so SwiftUI never has to cut the line itself.
        let room = textWidth - 10
        return DictationText.tail(of: words) { NSAttributedString(string: $0, attributes: attributes).size().width <= room }
    }
}

/// "Copied to clipboard": a small capsule where the pill was, its clipboard popping in and the words rising into place,
/// so a dictation that couldn't be pasted is never a mystery.
struct CopiedToast: View {
    let text: String
    @State private var appeared = false
    /// A headless render draws it as it ends up (there's no animation to run).
    @Environment(\.staticRender) private var staticRender
    private var shown: Bool { appeared || staticRender }

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "doc.on.clipboard.fill")
                .font(.system(size: 13, weight: .semibold))
                .scaleEffect(shown ? 1 : 0.3)
                .rotationEffect(.degrees(shown ? 0 : -25))
            Text(text)
                .font(.system(size: 14, weight: .medium))
                .lineLimit(1)
                .opacity(shown ? 1 : 0)
                .offset(y: shown ? 0 : 4)
        }
        .foregroundStyle(Theme.ink)
        .padding(.horizontal, 18)
        .frame(maxHeight: .infinity)
        .background(Capsule(style: .continuous).fill(Theme.paper))
        .overlay(Capsule(style: .continuous).strokeBorder(Theme.hairline))
        .scaleEffect(shown ? 1 : 0.9)
        .padding(2)
        // Centred in the panel, which is as wide as the pill.
        .frame(maxWidth: .infinity)
        .environment(\.colorScheme, .light)
        .onAppear { withAnimation(.spring(response: 0.4, dampingFraction: 0.55)) { appeared = true } }
    }
}

/// The words of a paste where Accessibility couldn't say if a text box has focus (many Electron apps), handed to the
/// clipboard only when an app reads them, so it's known whether anything took the paste. If nothing did, `settle`
/// writes them onto the clipboard outright (a promise is gone if Sona quits), unless something has replaced them.
// @unchecked: its state is under `lock` (the clipboard asks for the words on whatever thread it likes).
final class PasteWatch: NSObject, NSPasteboardItemDataProvider, @unchecked Sendable {
    private let lock = NSLock()
    private var text = ""
    private var changeCount = -1
    private var _taken = false

    /// An app has read the words.
    var taken: Bool { lock.withLock { _taken } }

    /// The words it hands over, set before they go on the clipboard.
    func arm(_ text: String) { lock.withLock { self.text = text } }

    /// The clipboard's change count once they're on it.
    func written(changeCount: Int) { lock.withLock { self.changeCount = changeCount } }

    func pasteboard(_ pasteboard: NSPasteboard?, item: NSPasteboardItem, provideDataForType type: NSPasteboard.PasteboardType) {
        let text = lock.withLock { () -> String in
            _taken = true
            return self.text
        }
        item.setString(text, forType: type)
    }

    @MainActor func settle() {
        let (text, ours) = lock.withLock { (self.text, changeCount) }
        let pasteboard = NSPasteboard.general
        guard pasteboard.changeCount == ours else { return }
        pasteboard.clearContents()
        pasteboard.writeObjects([Dictation.clipboardItem(text, concealed: false)])
    }
}

/// What Accessibility says about the focused element, in one read: is it a place to paste, and what's just before the
/// caret (for the space in front of a paste). Apps that hide their text (many Electron apps, some terminals) come back
/// unreadable or unknown, and the caller then guesses.
enum FocusedText {
    enum Caret: Sendable {
        /// This character is just before the caret (or before the selection a paste would replace).
        case after(Character)
        /// Nothing before it: the caret is at the start, or it's a password field (never read).
        case start
        case unknown
    }

    struct Read: Sendable {
        var focus: DictationText.Focus
        var caret: Caret
        /// A password field (AXSecureTextField): copied, never pasted into.
        var secure = false
    }

    /// Safe off the main thread (it only asks Accessibility and NSWorkspace), so it runs while the last audio comes
    /// in. `caret` false: what's before the caret isn't read.
    static func read(caret readCaret: Bool = true) -> Read {
        let unreadable = Read(focus: .unreadable, caret: .unknown)
        guard AXIsProcessTrusted() else { return unreadable }
        let system = AXUIElementCreateSystemWide()
        // A hung app mustn't hold the paste up: the longest any Accessibility call here waits.
        _ = AXUIElementSetMessagingTimeout(system, 0.3)
        var focused: CFTypeRef?
        let status = AXUIElementCopyAttributeValue(system, kAXFocusedUIElementAttribute as CFString, &focused)
        // "No value" is nothing focused, but an app that hides its text can say it too: it only counts when the app has
        // no focused window either (the desktop, an app with no window).
        if status == .noValue { return Read(focus: noFocusedWindow() ? .nothing : .unreadable, caret: .unknown) }
        guard status == .success, let focused, CFGetTypeID(focused) == AXUIElementGetTypeID() else { return unreadable }
        let element = focused as! AXUIElement

        let role = string(element, kAXRoleAttribute)
        let secure = string(element, kAXSubroleAttribute) == kAXSecureTextFieldSubrole
        var editable: CFTypeRef?
        _ = AXUIElementCopyAttributeValue(element, "AXEditable" as CFString, &editable)
        func settable(_ attribute: String) -> Bool {
            var yes: DarwinBoolean = false
            return AXUIElementIsAttributeSettable(element, attribute as CFString, &yes) == .success && yes.boolValue
        }
        let focus = DictationText.Focus.element(
            role: role, editable: editable as? Bool == true,
            settableText: settable(kAXSelectedTextRangeAttribute) || settable(kAXValueAttribute))
        // A password field is never read.
        return Read(focus: focus, caret: secure ? .start : readCaret ? caret(of: element) : .unknown, secure: secure)
    }

    private static func string(_ element: AXUIElement, _ attribute: String) -> String? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else { return nil }
        return value as? String
    }

    /// The frontmost app has no focused window (or there's no frontmost app). Any other answer, errors included, is no.
    private static func noFocusedWindow() -> Bool {
        guard let pid = NSWorkspace.shared.frontmostApplication?.processIdentifier else { return true }
        var window: CFTypeRef?
        return AXUIElementCopyAttributeValue(AXUIElementCreateApplication(pid), kAXFocusedWindowAttribute as CFString, &window) == .noValue
    }

    private static func caret(of element: AXUIElement) -> Caret {
        var selection: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXSelectedTextRangeAttribute as CFString, &selection) == .success,
            let selection, CFGetTypeID(selection) == AXValueGetTypeID()
        else { return .unknown }
        var selected = CFRange()
        guard AXValueGetValue(selection as! AXValue, .cfRange, &selected), selected.location != kCFNotFound else { return .unknown }
        if selected.location <= 0 { return .start }
        // The two units before the caret, so half an emoji still comes back whole; the last character is the one
        // just before it.
        let from = max(0, selected.location - 2)
        var window = CFRange(location: from, length: selected.location - from)
        if let range = AXValueCreate(.cfRange, &window) {
            var piece: CFTypeRef?
            if AXUIElementCopyParameterizedAttributeValue(element, kAXStringForRangeParameterizedAttribute as CFString, range, &piece) == .success,
                let last = (piece as? String)?.last
            {
                return .after(last)
            }
        }
        // A field that doesn't answer for a range: read all of its text.
        if let text = string(element, kAXValueAttribute) {
            let units = text as NSString
            if selected.location <= units.length, let last = units.substring(with: units.rangeOfComposedCharacterSequence(at: selected.location - 1)).last {
                return .after(last)
            }
        }
        return .unknown
    }
}

/// While dictation is on the fn key, fn/🌐 does nothing by itself (otherwise each press opens the emoji picker).
/// Uses the same private HIToolbox calls System Settings uses, and puts the old setting back when dictation is
/// turned off, moves to another key, or the app quits.
enum FnKey {
    private typealias Get = @convention(c) () -> Int
    private typealias Update = @convention(c) (Int) -> Void
    private static let savedKey = "fnUsageBeforeDictation"

    private static func functions() -> (Get, Update)? {
        guard let handle = dlopen("/System/Library/Frameworks/Carbon.framework/Frameworks/HIToolbox.framework/HIToolbox", RTLD_LAZY),
            let get = dlsym(handle, "TISGetFnUsageType"), let update = dlsym(handle, "TISUpdateFnUsageType")
        else { return nil }
        return (unsafeBitCast(get, to: Get.self), unsafeBitCast(update, to: Update.self))
    }

    static func takeOver() {
        guard let (get, update) = functions() else { return }
        let current = get() & 0xFF
        guard current != 0 else { return }
        // Keep the first saved value: after a crash we're "taking over" from our own Do Nothing.
        if UserDefaults.standard.object(forKey: savedKey) == nil { UserDefaults.standard.set(current, forKey: savedKey) }
        update(0)
    }

    static func restore() {
        guard let saved = UserDefaults.standard.object(forKey: savedKey) as? Int, let (get, update) = functions() else { return }
        // Only if it's still our Do Nothing: if the user picked something else meanwhile, that wins.
        if get() & 0xFF == 0 { update(saved) }
        UserDefaults.standard.removeObject(forKey: savedKey)
    }
}
