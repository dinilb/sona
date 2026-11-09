import Foundation
import NotesKit

/// How long a note's audio stays. `.thirtyDays` deletes a note's audio once the note started over
/// 30 days ago, `.deleteAfterTranscribing` keeps none (the Processor doesn't even keep it then), `.forever` keeps it
/// all. A note with Keep audio (`keep_audio: true`) keeps its audio whatever the setting. Only the audio goes (the
/// .m4a, or a WAV not converted yet), each file with a coordinated delete, never the note itself. A note this iPhone
/// can't read now (iCloud evicted its .md) is left alone: its Keep audio can't be checked. Blocking: call these off
/// the main thread.
nonisolated enum AudioRetention {
    static let days = 30
    /// A note's own audio files, by extension.
    static let audioExtensions = ["m4a", "wav", "mac.wav"]

    /// Whether a note's audio stays under `policy` at `now`. A note whose start can't be read keeps it.
    static func keeps(startedAt: Date?, keepAudio: Bool, policy: AudioPolicy, now: Date = Date()) -> Bool {
        if keepAudio { return true }
        switch policy {
        case .forever: return true
        case .deleteAfterTranscribing: return false
        case .thirtyDays:
            guard let startedAt else { return true }
            return now.timeIntervalSince(startedAt) <= Double(days) * 86_400
        }
    }

    /// The notes under each `Conversations` folder in `folders` whose audio `policy` doesn't keep at `now`, as each
    /// note's audio files (here, or only in iCloud). Its length is what a switch to `policy` would delete.
    static func expired(in folders: [URL], policy: AudioPolicy, now: Date = Date()) -> [[URL]] {
        guard policy != .forever else { return [] }
        let fm = FileManager.default
        // A day folder is the day its notes started: one newer than the cutoff day holds nothing 30 days old.
        let cutoffDay = policy == .thirtyDays ? NoteWriter.dayString(now.addingTimeInterval(-Double(days) * 86_400)) : nil
        var out: [[URL]] = []
        for conversations in folders {
            let store = NoteStore(root: conversations)
            for day in store.days() {
                if let cutoffDay, day > cutoffDay { continue }
                let dir = conversations.appendingPathComponent(day, isDirectory: true)
                let names = Set((try? fm.contentsOfDirectory(atPath: dir.path)) ?? [])
                for name in names.sorted() where name.hasSuffix(".md") && !name.hasPrefix(".") {
                    let stem = String(name.dropLast(3))
                    let audio = audioExtensions
                        .filter { names.contains("\(stem).\($0)") || names.contains(".\(stem).\($0).icloud") }
                        .map { dir.appendingPathComponent("\(stem).\($0)") }
                    guard !audio.isEmpty, let note = try? store.readHeader(url: dir.appendingPathComponent(name)) else { continue }
                    if !keeps(startedAt: note.startedAt, keepAudio: note.keepAudio, policy: policy, now: now) {
                        out.append(audio)
                    }
                }
            }
        }
        return out
    }

    /// What switching to `policy` deletes, for the confirm before a stricter setting: the notes whose audio goes now,
    /// and the notes iCloud took off this iPhone whose audio may go once they download (the sweep skips them until
    /// then, as their Keep audio can't be read, and then deletes it without asking again).
    struct Removal: Equatable, Sendable {
        var notes: Int
        var notDownloaded: Int
        /// At most this many notes lose their audio ("up to" when `notDownloaded` isn't 0).
        var upTo: Int { notes + notDownloaded }
    }

    static func removal(by policy: AudioPolicy, in folders: [URL], now: Date = Date()) -> Removal {
        Removal(
            notes: expired(in: folders, policy: policy, now: now).count,
            notDownloaded: notDownloaded(in: folders, policy: policy, now: now))
    }

    /// The notes only in iCloud (just a `.<name>.md.icloud` stub here) with audio that `policy` may delete once they
    /// download: in 30-day mode only those whose name says they started over 30 days ago. Never starts a download.
    static func notDownloaded(in folders: [URL], policy: AudioPolicy, now: Date = Date()) -> Int {
        guard policy != .forever else { return 0 }
        let fm = FileManager.default
        let cutoffDay = policy == .thirtyDays ? NoteWriter.dayString(now.addingTimeInterval(-Double(days) * 86_400)) : nil
        var count = 0
        for conversations in folders {
            for day in NoteStore(root: conversations).days() {
                if let cutoffDay, day > cutoffDay { continue }
                let dir = conversations.appendingPathComponent(day, isDirectory: true)
                let names = Set((try? fm.contentsOfDirectory(atPath: dir.path)) ?? [])
                for name in names where name.hasPrefix(".") && name.hasSuffix(".md.icloud") {
                    let stem = String(name.dropFirst().dropLast(".md.icloud".count))
                    guard !stem.isEmpty, !names.contains("\(stem).md") else { continue }
                    let hasAudio = audioExtensions.contains {
                        names.contains("\(stem).\($0)") || names.contains(".\(stem).\($0).icloud")
                    }
                    guard hasAudio else { continue }
                    // Its start from its name ("09-05 Title"): one whose name has no time keeps its audio, like a
                    // note whose start can't be read.
                    let clock = String(stem.prefix(5))
                    let isTime = clock.range(of: #"^\d{2}-\d{2}$"#, options: .regularExpression) != nil
                    let started = isTime ? ConversationNote.parse(day, clock.replacingOccurrences(of: "-", with: ":")) : nil
                    if !keeps(startedAt: started, keepAudio: false, policy: policy, now: now) { count += 1 }
                }
            }
        }
        return count
    }

    /// Deletes the audio `expired` finds. Returns how many notes lost their audio. Never logs a title.
    @discardableResult
    static func sweep(_ folders: [URL], policy: AudioPolicy, now: Date = Date()) -> Int {
        var removed = 0
        for audio in expired(in: folders, policy: policy, now: now) {
            do {
                for file in audio { try delete(file) }
                removed += 1
            } catch {
                Log.note("couldn't delete a note's audio for the audio setting: \(Log.describe(error))")
            }
        }
        if removed > 0 { Log.note("audio setting \(policy.rawValue): deleted the audio of \(removed) note(s)") }
        return removed
    }

    /// Deletes `file` if it's here, or if iCloud evicted it (only its hidden `.<name>.icloud` stub is here): deleting
    /// it by its own name deletes it from iCloud, and the stub goes too if that left it.
    static func delete(_ file: URL) throws {
        let fm = FileManager.default
        if fm.fileExists(atPath: file.path) { try NotesLocation.coordinatedDelete(file) }
        let stub = file.deletingLastPathComponent().appendingPathComponent(".\(file.lastPathComponent).icloud")
        guard fm.fileExists(atPath: stub.path) else { return }
        try? NotesLocation.coordinatedDelete(file)
        if fm.fileExists(atPath: stub.path) { try NotesLocation.coordinatedDelete(stub) }
    }
}
