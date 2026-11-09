import Foundation
import NotesKit

/// A note as the list shows it, read from its header.
nonisolated struct NoteSummary: Identifiable, Hashable, Sendable {
    /// NoteStore's id: `2026-11-02/14-03 Title`.
    var id: String
    var url: URL
    /// The first-words title (also in the file name).
    var title: String
    /// The on-device model's title (`ai_title`), if it has one.
    var aiTitle: String?
    var startedAt: Date?
    /// When it ended, from its header's `end` (past midnight when that's before the start); nil when it has none.
    /// Rows should end here, and fall back on the start plus the duration text only without it.
    var endedAt: Date? = nil
    /// As the note says it: "18m 28s".
    var duration: String
    var speakers: [String]
    /// "Apple Watch" for the watch's recordings; nil for the iPhone's own.
    var source: String?
    /// Where it was recorded, a short street name ("4 Main St"); and where it stopped, when that's well away.
    var place: String?
    var placeEnd: String?
    /// Keep audio: its audio stays for good, whatever the audio setting.
    var keepAudio: Bool
    /// It has audio beside it (an .m4a, or a WAV not converted yet), on this iPhone or only in iCloud.
    var hasAudio: Bool = false
    /// It's where notes go, not still waiting on this iPhone (in staging) to move there: false is "On this iPhone, not
    /// synced yet".
    var isSynced: Bool = true
    /// In the "On this iPhone" folder after notes went somewhere else: it stays on this iPhone for good (not "yet").
    var keptOnIPhone: Bool = false
    /// False when iCloud has it but this iPhone doesn't right now (evicted to save space): it's listed from its file
    /// name alone (no AI title, place or length), and `NotesService.open` downloads it.
    var isDownloaded: Bool = true

    /// What lists show: the AI title when it has one, else the first-words title (like `ConversationNote.displayTitle`).
    var displayTitle: String {
        if let aiTitle, !aiTitle.trimmingCharacters(in: .whitespaces).isEmpty { return aiTitle }
        return title
    }

    /// The id of a note still in staging when a different note with its name is already where notes go.
    static let stagedPrefix = "local:"

    init(_ note: ConversationNote) {
        id = note.id
        url = note.url
        title = note.title
        aiTitle = note.aiTitle
        startedAt = note.startedAt
        endedAt = note.endedAt
        duration = note.duration
        speakers = note.speakers
        source = note.source
        place = note.place
        placeEnd = note.placeEnd
        keepAudio = note.keepAudio
    }

    /// A note iCloud evicted from this iPhone, from its name alone (`<day>/HH-MM Title`): `url` is the note's own
    /// `.md`, which isn't here until it's downloaded.
    init(evicted url: URL, day: String, stem: String) {
        id = "\(day)/\(stem)"
        self.url = url
        let clock = String(stem.prefix(5))
        let isTime = clock.range(of: #"^\d{2}-\d{2}$"#, options: .regularExpression) != nil
        let rest = isTime ? String(stem.dropFirst(5)).trimmingCharacters(in: .whitespaces) : stem
        title = rest.isEmpty ? "Conversation" : rest
        startedAt = ConversationNote.parse(day, isTime ? clock.replacingOccurrences(of: "-", with: ":") : "00:00")
        duration = ""
        speakers = []
        keepAudio = false
        isDownloaded = false
    }

    /// Every note under `conversations`, newest first, marked `isSynced` as given. Reads only each note's header (not
    /// its transcript), but still one file per note: call it off the main thread. A note iCloud evicted (only its
    /// hidden `.<name>.md.icloud` stub is here) is listed from its file name, and its download starts (a few KB) so
    /// the next read has its header.
    static func all(in conversations: URL, synced: Bool = true) -> [NoteSummary] {
        let fm = FileManager.default
        let store = NoteStore(root: conversations)
        var out: [NoteSummary] = []
        for day in store.days() {
            let dir = conversations.appendingPathComponent(day, isDirectory: true)
            let names = Set((try? fm.contentsOfDirectory(atPath: dir.path)) ?? [])
            func has(_ stem: String, _ ext: String) -> Bool {
                names.contains("\(stem).\(ext)") || names.contains(".\(stem).\(ext).icloud")
            }
            for name in names {
                var note: NoteSummary
                let stem: String
                if name.hasSuffix(".md"), !name.hasPrefix(".") {
                    stem = String(name.dropLast(3))
                    let url = dir.appendingPathComponent(name)
                    // Like NoteStore: regular files only, no symlinks.
                    var st = stat()
                    guard lstat(url.path, &st) == 0, (st.st_mode & S_IFMT) == S_IFREG,
                        let header = try? store.readHeader(url: url)
                    else { continue }
                    note = NoteSummary(header)
                } else if name.hasPrefix("."), name.hasSuffix(".md.icloud") {
                    stem = String(name.dropFirst().dropLast(".md.icloud".count))
                    guard !stem.isEmpty, !names.contains("\(stem).md") else { continue }  // the real one is listed
                    let url = dir.appendingPathComponent("\(stem).md")
                    try? fm.startDownloadingUbiquitousItem(at: url)
                    note = NoteSummary(evicted: url, day: day, stem: stem)
                } else {
                    continue
                }
                note.hasAudio = has(stem, "m4a") || has(stem, "wav")
                note.isSynced = synced
                out.append(note)
            }
        }
        return newestFirst(out)
    }

    /// The id of a note kept "On this iPhone" (`list`'s `kept`) when a note with its name is listed already.
    static let keptPrefix = "iphone:"

    /// The list: the notes where notes go (`destination`, nil while they wait in staging) and the ones still in
    /// `staging` waiting to move there (`isSynced` false), newest first. Two with the same id and the same `.md` are
    /// one note whose move was cut short: listed once, from `destination`. A different staged note with a name taken
    /// there gets `stagedPrefix` on its id, so ids stay unique (open notes by their `url`, never by resolving an id).
    /// `kept`: the "On this iPhone" folder's notes after notes went somewhere else. They stay there (moving them to
    /// iCloud unasked would undo that choice), and listed (`isSynced` false) they can still be opened and deleted:
    /// nothing else shows that folder. One with a name already listed gets `keptPrefix` on its id.
    static func list(destination: URL?, staging: URL, kept: URL? = nil) -> [NoteSummary] {
        let there = destination.map { all(in: $0, synced: true) } ?? []
        var urls: [String: URL] = [:]
        for note in there { urls[note.id] = note.url }
        var out = there
        for var note in all(in: staging, synced: false) {
            if let other = urls[note.id] {
                if FileManager.default.contentsEqual(atPath: note.url.path, andPath: other.path) { continue }
                note.id = stagedPrefix + note.id
            }
            out.append(note)
        }
        if let kept {
            let taken = Set(out.map(\.id))
            for var note in all(in: kept, synced: false) {
                if taken.contains(note.id) { note.id = keptPrefix + note.id }
                note.keptOnIPhone = true
                out.append(note)
            }
        }
        return newestFirst(out)
    }

    private static func newestFirst(_ notes: [NoteSummary]) -> [NoteSummary] {
        notes.sorted { ($0.startedAt ?? .distantPast, $0.id) > ($1.startedAt ?? .distantPast, $1.id) }
    }
}
