import Foundation

/// Where notes go, chosen in onboarding.
nonisolated enum NotesChoice: String, Sendable, CaseIterable {
    /// The app's iCloud container: synced with the Mac.
    case icloud
    /// A folder on this iPhone, in iCloud Backup but never in iCloud Drive.
    case iphone
    /// A folder picked with the folder picker.
    case folder
}

/// How long a note's audio stays on this iPhone.
nonisolated enum AudioPolicy: String, Sendable, CaseIterable {
    /// Deleted once the note is 30 days old, unless the note has Keep audio.
    case thirtyDays
    case forever
    /// No audio kept once the note is written.
    case deleteAfterTranscribing
}

/// The choices onboarding and Settings make, in `UserDefaults.standard` (thread-safe, so fine off the main actor).
nonisolated enum V1Settings {
    /// Nil until onboarding has saved one.
    static var notesChoice: NotesChoice? {
        get { UserDefaults.standard.string(forKey: "notesChoice").flatMap(NotesChoice.init(rawValue:)) }
        set { UserDefaults.standard.set(newValue?.rawValue, forKey: "notesChoice") }
    }

    static var audioPolicy: AudioPolicy {
        get { UserDefaults.standard.string(forKey: "audioPolicy").flatMap(AudioPolicy.init(rawValue:)) ?? .thirtyDays }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: "audioPolicy") }
    }

    /// An audio setting was saved (onboarding or Settings), not just the default read back.
    static var audioPolicySaved: Bool { UserDefaults.standard.string(forKey: "audioPolicy") != nil }

    static var onboardingDone: Bool {
        get { UserDefaults.standard.bool(forKey: "onboardingDone") }
        set { UserDefaults.standard.set(newValue, forKey: "onboardingDone") }
    }

    /// The first screen said Sona downloads its speech model once and how big it is, and he went on (App Review
    /// 4.2.3(ii): disclose the size and prompt before a first-launch download). From then on the model downloads by
    /// itself, with no button: `NotesService.ensureModels()`.
    static var modelDownloadAllowed: Bool {
        get { UserDefaults.standard.bool(forKey: "modelDownloadAllowed") }
        set { UserDefaults.standard.set(newValue, forKey: "modelDownloadAllowed") }
    }
}
