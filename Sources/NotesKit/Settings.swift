import Foundation
import os

/// The whole settings file (`settings.json` in the support folder). The app writes it; the CLI and the MCP
/// server read it (the notes folder, and whether AI access is on).
public struct Settings: Codable, Equatable, Sendable {
    /// Where notes go. Conversations land in `<notesFolder>/Conversations/YYYY-MM-DD/`.
    public var notesFolder: String
    /// Record all day and turn conversations into notes. Off: the mic only opens while the dictation key is held.
    public var alwaysOn: Bool
    /// Hold `dictationKey` in any app to dictate.
    public var dictation: Bool
    /// The dictation shortcut (still "dictationKey" in the file: it was only a key before).
    public var dictationKey: DictationShortcut
    /// AI apps can read the notes and the live transcript through `sona-mcp`.
    public var mcp: Bool
    /// Separate speakers in the live transcript.
    public var speakers: Bool
    /// This long with no speech ends a conversation. Not in the app's settings (3 minutes); test homes change it.
    public var quietMinutes: Double
    /// "v2" (English) or "v3" (25 languages) for notes. Not in the app's settings: the live model is English-only.
    public var model: String
    /// Keep the conversation audio as a .wav next to the note. Not in the app's settings (off).
    public var keepAudio: Bool
    public var launchAtLogin: Bool
    /// The input device's UID (`InputDevices`). Nil: automatic, the built-in mic and never Bluetooth.
    public var micUID: String?
    /// Listening is paused until then (state, kept here so a relaunch stays paused).
    public var pausedUntil: Date?
    /// The first-run screen is done. Nothing listens before that. A settings file from before it existed counts
    /// as done, so someone already using the app is never asked again.
    public var onboarded: Bool
    /// "Words it should know": spellings to fix in dictation, the live transcript and new notes.
    public var words: [WordFix]
    /// Months in the window's sidebar opened or closed by a click, by `yyyy-MM` (state, so it lasts past a relaunch).
    /// The rest follow the default: the newest month open, older ones closed.
    public var openMonths: [String: Bool]
    /// Also hear what this Mac plays (a video, a call), through a Core Audio tap, as its own track ("Mac audio").
    /// Off until turned on: it needs the System Audio Recording permission, asked for then.
    public var macAudio: Bool

    public init(
        notesFolder: String = Paths.defaultNotesFolder.path, alwaysOn: Bool = true, dictation: Bool = true,
        dictationKey: DictationShortcut = .fn, mcp: Bool = true, speakers: Bool = true, quietMinutes: Double = 3,
        model: String = "v2", keepAudio: Bool = false, launchAtLogin: Bool = true, micUID: String? = nil,
        pausedUntil: Date? = nil, onboarded: Bool = false, words: [WordFix] = [], openMonths: [String: Bool] = [:],
        macAudio: Bool = false
    ) {
        self.notesFolder = notesFolder
        self.alwaysOn = alwaysOn
        self.dictation = dictation
        self.dictationKey = dictationKey
        self.mcp = mcp
        self.speakers = speakers
        self.quietMinutes = quietMinutes
        self.model = model
        self.keepAudio = keepAudio
        self.launchAtLogin = launchAtLogin
        self.micUID = micUID
        self.pausedUntil = pausedUntil
        self.onboarded = onboarded
        self.words = words
        self.openMonths = openMonths
        self.macAudio = macAudio
    }

    public var notesURL: URL { URL(fileURLWithPath: (notesFolder as NSString).expandingTildeInPath, isDirectory: true) }
    public var conversationsURL: URL { notesURL.appendingPathComponent("Conversations", isDirectory: true) }

    /// Paused right now.
    public func isPaused(now: Date = Date()) -> Bool { pausedUntil.map { $0 > now } ?? false }

    enum CodingKeys: String, CodingKey {
        case notesFolder, alwaysOn, dictation, dictationKey, mcp, speakers, quietMinutes, model, keepAudio, launchAtLogin
        case micUID, pausedUntil, onboarded, words, openMonths, macAudio
    }

    /// Missing keys fall back to defaults, so an older file still loads.
    public init(from decoder: Decoder) throws {
        let d = Settings()
        let c = try decoder.container(keyedBy: CodingKeys.self)
        notesFolder = try c.decodeIfPresent(String.self, forKey: .notesFolder) ?? d.notesFolder
        alwaysOn = try c.decodeIfPresent(Bool.self, forKey: .alwaysOn) ?? d.alwaysOn
        dictation = try c.decodeIfPresent(Bool.self, forKey: .dictation) ?? d.dictation
        dictationKey = (try? c.decodeIfPresent(DictationShortcut.self, forKey: .dictationKey)) ?? d.dictationKey
        mcp = try c.decodeIfPresent(Bool.self, forKey: .mcp) ?? d.mcp
        speakers = try c.decodeIfPresent(Bool.self, forKey: .speakers) ?? d.speakers
        quietMinutes = try c.decodeIfPresent(Double.self, forKey: .quietMinutes) ?? d.quietMinutes
        model = try c.decodeIfPresent(String.self, forKey: .model) ?? d.model
        keepAudio = try c.decodeIfPresent(Bool.self, forKey: .keepAudio) ?? d.keepAudio
        launchAtLogin = try c.decodeIfPresent(Bool.self, forKey: .launchAtLogin) ?? d.launchAtLogin
        micUID = try c.decodeIfPresent(String.self, forKey: .micUID)
        if micUID?.isEmpty == true { micUID = nil }
        // A date as ISO 8601 (what `save` writes); anything else is ignored rather than failing the whole file.
        pausedUntil = (try? c.decodeIfPresent(String.self, forKey: .pausedUntil)).flatMap { $0 }
            .flatMap { ISO8601DateFormatter().date(from: $0) }
        onboarded = try c.decodeIfPresent(Bool.self, forKey: .onboarded) ?? true
        words = (try? c.decodeIfPresent([WordFix].self, forKey: .words)) ?? []
        openMonths = (try? c.decodeIfPresent([String: Bool].self, forKey: .openMonths)) ?? [:]
        macAudio = try c.decodeIfPresent(Bool.self, forKey: .macAudio) ?? d.macAudio
        if !["v2", "v3"].contains(model) { model = "v2" }
        quietMinutes = min(max(quietMinutes, 0.05), 120)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(notesFolder, forKey: .notesFolder)
        try c.encode(alwaysOn, forKey: .alwaysOn)
        try c.encode(dictation, forKey: .dictation)
        try c.encode(dictationKey, forKey: .dictationKey)
        try c.encode(mcp, forKey: .mcp)
        try c.encode(speakers, forKey: .speakers)
        try c.encode(quietMinutes, forKey: .quietMinutes)
        try c.encode(model, forKey: .model)
        try c.encode(keepAudio, forKey: .keepAudio)
        try c.encode(launchAtLogin, forKey: .launchAtLogin)
        try c.encodeIfPresent(micUID, forKey: .micUID)
        try c.encodeIfPresent(pausedUntil.map { ISO8601DateFormatter().string(from: $0) }, forKey: .pausedUntil)
        try c.encode(onboarded, forKey: .onboarded)
        try c.encode(words, forKey: .words)
        try c.encode(openMonths, forKey: .openMonths)
        try c.encode(macAudio, forKey: .macAudio)
    }

    /// The settings file as it is on disk.
    enum OnDisk {
        /// No file: a new install.
        case missing
        /// There, but it doesn't decode (cut short, edited by hand).
        case unreadable
        case read(Settings)
    }

    static func onDisk() -> OnDisk {
        guard FileManager.default.fileExists(atPath: Paths.settingsFile.path) else { return .missing }
        guard let data = try? Data(contentsOf: Paths.settingsFile), let settings = try? JSONDecoder().decode(Settings.self, from: data)
        else { return .unreadable }
        return .read(settings)
    }

    /// The defaults when there's no file (a new install). A file that's there but can't be read still means this Mac
    /// was set up already, so never the first-run screen again; but nothing that records or shares is assumed on:
    /// always-on, AI access and this Mac's audio are off. The file is left as it is (the app only saves when a setting
    /// is changed), so it can still be fixed by hand.
    public static func load() -> Settings {
        switch onDisk() {
        case .missing: return Settings()
        case .read(let settings): return settings
        case .unreadable:
            if warnedUnreadable.withLock({ done in defer { done = true }; return !done }) {
                Log.note("settings.json can't be read: always-on, AI access and Mac audio are off until a setting is changed")
            }
            return Settings(alwaysOn: false, mcp: false, onboarded: true, macAudio: false)
        }
    }

    /// One log line per process, however often an MCP server reads the file.
    private static let warnedUnreadable = OSAllocatedUnfairLock(initialState: false)

    /// AI apps may read the notes and the live transcript (`sona-mcp`, `sona mcp`): only when the settings file is
    /// there and reads, the first run is done and AI access is on. No file, or one that can't be read, is off.
    public static var aiAccessAllowed: Bool {
        guard case .read(let settings) = onDisk() else { return false }
        return settings.onboarded && settings.mcp
    }

    /// Readable by this user only (0600), like everything in the support folder.
    public func save() throws {
        Paths.ensure(Paths.support)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        try NoteWriter.writePrivate(encoder.encode(self), to: Paths.settingsFile)
    }
}
