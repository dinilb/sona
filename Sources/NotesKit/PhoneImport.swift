#if os(macOS)
import CryptoKit
import Foundation
import os

/// Brings the iPhone's notes into this Mac's notes folder.
///
/// The iPhone app writes its notes the way this Mac does (`<day>/HH-MM <title>.md`, its `.json`, and the kept audio as
/// `.m4a`) into iCloud Drive, and iCloud puts that folder on this Mac. This copies each note into
/// `<notes>/Conversations`, where the app, search and the MCP server already look, with the same file names.
///
/// - The notes can be in more than one place (`defaultSources`). A note in two of them is copied once, from the first,
///   unless that copy isn't whole (not all there, or not readable yet) and the other is.
/// - No note is ever deleted, on either side. The one thing removed is this importer's own hidden temp file, left in a
///   day folder here by a copy that was stopped halfway, once it is a few minutes old.
/// - A note is copied whole or not at all: its `.md` and `.json` both there, and none of its files still coming down
///   from iCloud. Anything else is tried again on the next run.
/// - Later runs cost a directory listing and a stat per file (and a listing of each day folder here, to find the temp
///   files). A note is read again only when the iPhone's copy changed, and replaced only if this Mac's copy is still
///   as it was copied (a speaker renamed here, or the note deleted here, stays as it is). An edited copy still gets
///   the place, Keep audio and AI title the iPhone adds to a note later (`mergeLaterKeys`), and a title this Mac made
///   for a note (`TitlesFile`) goes into its untouched copy here straight away (`addTitle`, `addMacTitle`).
/// - What was copied is remembered in `statePath`, so a note deleted here doesn't come back. The list belongs to
///   the notes folder it copied into: with another one (Settings) it starts over, and copies into the new folder.
public enum PhoneImport {
    /// What one run did, in notes.
    public struct Summary: Equatable, Sendable {
        /// New on this Mac.
        public var imported = 0
        /// The iPhone changed it and this Mac's copy hadn't been touched, so it was replaced.
        public var updated = 0
        /// Nothing to do.
        public var unchanged = 0
        /// Skipped for now: not all there yet (still downloading from iCloud, or its .json hasn't come). The next run tries again.
        public var waiting = 0
        /// Skipped for good: the iPhone changed it, but it was edited or deleted on this Mac since it was copied. This Mac's stays.
        public var kept = 0
        /// Another import (the app's, or `sona import-phone`) was running, so this one did nothing.
        public var busy = false

        public var skipped: Int { waiting + kept }
        public var changed: Int { imported + updated }

        public init() {}
    }

    /// Where the iPhone app puts its notes in iCloud Drive, as this Mac has them, in the order they are read: the
    /// folder the user picked ("iCloud Drive/Sona"), then the app's own iCloud folder. Only the ones that exist
    /// are read. In a test home (`SONA_HOME`) it is just `PhoneInbox` there, so nothing that runs in a test home
    /// ever reads the real ones.
    public static var defaultSources: [URL] {
        if Paths.isTestHome { return [Paths.support.appendingPathComponent("PhoneInbox", isDirectory: true)] }
        let cloud = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Mobile Documents", isDirectory: true)
        return [
            cloud.appendingPathComponent("com~apple~CloudDocs/Sona/Conversations", isDirectory: true),
            cloud.appendingPathComponent("iCloud~com~dinilb~sona/Documents/Conversations", isDirectory: true),
        ]
    }

    /// What was copied, in the support folder.
    public static var defaultStatePath: URL { Paths.support.appendingPathComponent("phone-import.json") }

    /// A note's files; a note is its `.md`. The iPhone writes `.m4a`; `.wav` is the Mac's own kept-audio format.
    static let extensions = ["md", "json", "m4a", "wav"]
    /// Audio first and the `.md` last, so a note only shows up here once the rest of it is in place.
    private static let writeOrder = ["m4a", "wav", "json", "md"]

    /// One folder of the iPhone's notes (`sona import-phone --from`).
    @discardableResult
    public static func run(from source: URL, to conversations: URL, statePath: URL, log: (String) -> Void = { Log.note($0) }) -> Summary {
        run(from: [source], to: conversations, statePath: statePath, log: log)
    }

    /// Copies the iPhone's notes from `sources` into `conversations` (`<notes>/Conversations`) once. Cheap when
    /// nothing changed. A note that is in more than one source is copied from the first whole copy (the first
    /// source's if both are), and the others count as unchanged. `log` gets one line per thing that happened,
    /// counts only (never a title or a file name).
    @discardableResult
    public static func run(
        from sources: [URL] = defaultSources, to conversations: URL, statePath: URL, log: (String) -> Void = { Log.note($0) }
    ) -> Summary {
        var summary = Summary()
        // No iPhone folder here (yet), or it is the notes folder itself: nothing to bring over.
        let folders = sources.filter { isDirectory($0.path) && !sameFolder($0, conversations) }
        guard !folders.isEmpty else { return summary }

        // The app and the command line can both run it: one at a time, or they'd write the list over each other.
        Paths.ensure(statePath.deletingLastPathComponent())
        guard let lock = Lock.acquire(statePath.path + ".lock") else {
            summary.busy = true
            return summary
        }
        defer { lock.release() }

        // What an import that was stopped halfway left in the notes folder (none is running now: we hold the lock).
        clearLeftovers(in: conversations, log: log)

        // The list is for the notes folder it copied into. Another folder (Settings) starts from nothing: the
        // iPhone's notes are copied into it, and any already there with the same words are recognised, not copied
        // twice. A list from before its folder was recorded is taken to be for this one.
        var state = loadState(statePath, log: log)
        let root = conversations.standardizedFileURL.path
        let folderRecorded = state.destination == root
        if let was = state.destination, was != root {
            if !state.notes.isEmpty {
                log("phone import: the notes folder changed, so the iPhone's notes are copied into the new one from the start (ones already there with the same words are left as they are)")
            }
            state = State()
        }
        state.destination = root
        var importer = Importer(conversations: conversations, state: state)
        importer.dirty = !folderRecorded  // saved even if no note changes, so the folder is on record and this isn't said again
        func save() {
            do { try saveState(importer.state, to: statePath) } catch {
                logStatus("phone import: couldn't save its list of copied notes (\(Log.describe(error)))", key: statePath.path, log: log)
                return
            }
            importer.dirty = false
        }
        // The same note in two places is one note, and the first place has it, unless that copy isn't all there
        // yet and a later place's is (a .json that hasn't come, a file still coming from iCloud or not readable
        // yet): it would only wait while a whole one sits next to it. When both are whole, the first wins.
        var chosen: [String: SourceNote] = [:]
        var again = 0
        for folder in folders {
            for note in scan(folder) {
                guard let held = chosen[note.id] else {
                    chosen[note.id] = note
                    continue
                }
                again += 1
                if !isWhole(held), isWhole(note) { chosen[note.id] = note }
            }
        }
        for note in chosen.values.sorted(by: { $0.id < $1.id }) {
            importer.process(note)
            // A long first import keeps what it has done.
            if importer.dirty, importer.sinceSave >= 25 {
                save()
                importer.sinceSave = 0
            }
        }
        if importer.dirty { save() }

        summary = importer.summary
        summary.unchanged += again
        if summary.changed > 0 {
            log("phone import: \(summary.imported) new, \(summary.updated) updated")
        }
        if importer.keptNow > 0 {
            let n = importer.keptNow
            log("phone import: \(n) note\(n == 1 ? "" : "s") changed on the iPhone but \(n == 1 ? "was" : "were") edited or deleted here since, so this Mac's \(n == 1 ? "copy stays" : "copies stay")")
        }
        // Repeated every minute while it lasts: say it once.
        var status: [String] = []
        if importer.failures > 0 {
            status.append("couldn't copy \(importer.failures) note\(importer.failures == 1 ? "" : "s") (\(importer.lastFailure ?? "unknown error"))")
        }
        if summary.waiting > importer.failures {
            status.append("\(summary.waiting - importer.failures) not all there yet (still coming from iCloud)")
        }
        if status.isEmpty {
            lastStatus.withLock { $0[statePath.path] = nil }
        } else {
            logStatus("phone import: " + status.joined(separator: "; "), key: statePath.path, log: log)
        }
        return summary
    }

    // MARK: what is in the iPhone's folder

    private struct SourceFile {
        var url: URL
        var size: Int64
        /// Nanoseconds since 1970.
        var mtime: Int64
    }

    /// One note in the iPhone's folder: its files that are really there, and the ones iCloud has only left a
    /// placeholder for (`.Name.md.icloud`, from before iCloud Drive moved to the File Provider).
    private struct SourceNote {
        var dir: URL
        var day: String
        var stem: String
        var files: [String: SourceFile] = [:]
        var placeholders: Set<String> = []

        /// Like `NoteStore`'s ids: `2026-11-02/14-03 Budget talk`.
        var id: String { day + "/" + stem }

        /// The `.md` and the `.json` are both here as real files and none of its files is still a placeholder:
        /// what a note needs before it is copied.
        var isComplete: Bool { files["md"] != nil && files["json"] != nil && placeholders.isEmpty }
    }

    /// Complete, and everything of it that is here can be read. Only asked about a note that is in more than one
    /// folder (a permission check per file), to pick the copy that would not just wait.
    private static func isWhole(_ note: SourceNote) -> Bool {
        note.isComplete && note.files.values.allSatisfy { access($0.url.path, R_OK) == 0 }
    }

    /// Every note in one folder. Only day folders, only plain files (no hidden files, no symlinks).
    private static func scan(_ root: URL) -> [SourceNote] {
        var out: [SourceNote] = []
        for day in SearchIndex.entries(root.path).sorted() where SearchIndex.isDay(day) {
            let dirPath = root.path + "/" + day
            guard NoteWriter.isRealDirectory(dirPath) else { continue }
            let dir = URL(fileURLWithPath: dirPath, isDirectory: true)
            var notes: [String: SourceNote] = [:]
            for entry in SearchIndex.entries(dirPath) {
                var name = entry
                var placeholder = false
                if name.hasPrefix("."), name.hasSuffix(".icloud"), name.count > 8 {
                    name = String(name.dropFirst().dropLast(".icloud".count))
                    placeholder = true
                }
                guard !name.hasPrefix("."), let dot = name.lastIndex(of: ".") else { continue }
                let ext = String(name[name.index(after: dot)...])
                let stem = String(name[..<dot])
                guard extensions.contains(ext), !stem.isEmpty else { continue }
                if placeholder {
                    notes[stem, default: SourceNote(dir: dir, day: day, stem: stem)].placeholders.insert(ext)
                } else {
                    var st = stat()
                    guard lstat(dirPath + "/" + name, &st) == 0, (st.st_mode & S_IFMT) == S_IFREG else { continue }
                    notes[stem, default: SourceNote(dir: dir, day: day, stem: stem)].files[ext] = SourceFile(
                        url: dir.appendingPathComponent(name), size: Int64(st.st_size), mtime: nanoseconds(st))
                }
            }
            out.append(contentsOf: notes.values.filter { $0.files["md"] != nil || $0.placeholders.contains("md") })
        }
        return out
    }

    /// Asks iCloud for a file that isn't on this Mac yet. It only helps there; anywhere else it does nothing.
    private static func startDownload(_ url: URL) {
        try? FileManager.default.startDownloadingUbiquitousItem(at: url)
    }

    // MARK: what was copied

    struct State: Codable {
        var version = 1
        /// The notes folder (`<notes>/Conversations`, as a standardized path) these notes were copied into: the list
        /// is only good for that folder. Nil in a list written before it was recorded; that one is taken to be for
        /// the folder in use.
        var destination: String?
        /// By the iPhone's note id.
        var notes: [String: Note] = [:]

        struct Note: Codable, Equatable {
            /// The file name here, when it isn't the iPhone's: a note of this Mac's own already had that name.
            var stem: String?
            /// By extension.
            var files: [String: File]
        }

        struct File: Codable, Equatable {
            /// The iPhone's copy when it was last looked at.
            var size: Int64
            var mtime: Int64
            /// What was written here, so an edit made here shows.
            var sha256: String
        }
    }

    private static func loadState(_ url: URL, log: (String) -> Void) -> State {
        guard let data = try? Data(contentsOf: url) else { return State() }
        if let state = try? JSONDecoder().decode(State.self, from: data), state.version == 1 { return state }
        // Notes already here that match are recognised again; ones edited here would be copied next to them.
        log("phone import: its list of copied notes can't be read, so it starts a new one")
        return State()
    }

    private static func saveState(_ state: State, to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        try NoteWriter.writePrivate(encoder.encode(state), to: url)
    }

    private static let lastStatus = OSAllocatedUnfairLock(initialState: [String: String]())

    private static func logStatus(_ line: String, key: String, log: (String) -> Void) {
        let isNew = lastStatus.withLock { memo -> Bool in
            if memo[key] == line { return false }
            memo[key] = line
            return true
        }
        if isNew { log(line) }
    }

    // MARK: one run

    private struct Importer {
        let conversations: URL
        var state: State
        var summary = Summary()
        /// The list has changes that aren't saved yet.
        var dirty = false
        var sinceSave = 0
        /// Notes this run that were left as they are here on purpose, and ones that failed (with the last error's code).
        var keptNow = 0
        var failures = 0
        var lastFailure: String?

        enum Outcome { case imported, updated, unchanged, waiting, kept }

        mutating func process(_ note: SourceNote) {
            switch state.notes[note.id] == nil ? importNew(note) : refresh(note) {
            case .imported: summary.imported += 1
            case .updated: summary.updated += 1
            case .unchanged: summary.unchanged += 1
            case .waiting: summary.waiting += 1
            case .kept: summary.kept += 1
            }
        }

        private mutating func failed(_ error: Error) {
            failures += 1
            lastFailure = Log.describe(error)
        }

        private mutating func remember(_ id: String, _ note: State.Note) {
            state.notes[id] = note
            dirty = true
            sinceSave += 1
        }

        /// A day folder here, 0700 like NoteWriter's, and the Conversations folder above it.
        private func prepare(_ dir: URL) throws {
            try NoteWriter.makePrivateDirectory(dir)
            if NoteWriter.isRealDirectory(conversations.path) { chmod(conversations.path, 0o700) }
        }

        /// A note not copied before.
        private mutating func importNew(_ note: SourceNote) -> Outcome {
            // All of it or none: the .md and the .json both here, and none of its files still coming from iCloud.
            guard note.isComplete else {
                for ext in note.placeholders { PhoneImport.startDownload(note.dir.appendingPathComponent(note.stem + "." + ext)) }
                return .waiting
            }
            let dir = conversations.appendingPathComponent(note.day, isDirectory: true)
            var staged: [Staged] = []
            defer { for s in staged { unlink(s.temp.path) } }  // the ones that weren't moved into place
            do {
                try prepare(dir)
                for ext in PhoneImport.extensions {
                    if let file = note.files[ext] { staged.append(try PhoneImport.stage(file.url, ext: ext, in: dir)) }
                }
            } catch {
                failed(error)
                // A file iCloud hasn't downloaded can fail to read: ask for it, and the next run takes it.
                for ext in PhoneImport.extensions { PhoneImport.startDownload(note.dir.appendingPathComponent(note.stem + "." + ext)) }
                return .waiting
            }

            // This Mac may already have a file by that name. The same bytes: it's the same note (a list that was
            // lost), and it stays. Different ones: that's another note, never overwritten; this one gets a new name.
            func path(_ stem: String, _ ext: String) -> String { dir.path + "/" + stem + "." + ext }
            let clash = staged.contains { s in
                PhoneImport.exists(path(note.stem, s.ext)) && PhoneImport.sha256(ofFileAt: path(note.stem, s.ext)) != s.file.sha256
            }
            var stem = note.stem
            var writes = staged
            if clash {
                stem = freeStem(note.stem, in: dir)
            } else {
                writes = staged.filter { !PhoneImport.exists(path(note.stem, $0.ext)) }
            }
            do {
                for s in writes.sorted(by: { PhoneImport.rank($0.ext) < PhoneImport.rank($1.ext) }) {
                    try PhoneImport.move(s.temp, to: URL(fileURLWithPath: path(stem, s.ext)))
                }
            } catch {
                // What was moved stays; the next run finds it the same and moves the rest.
                failed(error)
                return .waiting
            }
            var files = Dictionary(uniqueKeysWithValues: staged.map { ($0.ext, $0.file) })
            // A title this Mac made for it that the iPhone hasn't folded in yet. The list keeps the titled copy as
            // the one copied, so the iPhone's next change still replaces it.
            if writes.contains(where: { $0.ext == "md" }),
                let sha = PhoneImport.addMacTitle(for: note, to: URL(fileURLWithPath: path(stem, "md")))
            {
                files["md"]?.sha256 = sha
            }
            remember(note.id, State.Note(stem: stem == note.stem ? nil : stem, files: files))
            return writes.isEmpty ? .unchanged : .imported
        }

        /// "Name 2", "Name 3"...: the first name none of whose files exist.
        private func freeStem(_ stem: String, in dir: URL) -> String {
            for n in 2..<10_000 {
                let candidate = "\(stem) \(n)"
                if !PhoneImport.extensions.contains(where: { PhoneImport.exists(dir.path + "/" + candidate + "." + $0) }) { return candidate }
            }
            return "\(stem) \(UUID().uuidString.prefix(8))"
        }

        /// A note copied before: has the iPhone's copy changed?
        private mutating func refresh(_ note: SourceNote) -> Outcome {
            guard let original = state.notes[note.id] else { return .unchanged }
            var rec = original
            defer { if rec != original { remember(note.id, rec) } }
            let dir = conversations.appendingPathComponent(note.day, isDirectory: true)
            let stem = rec.stem ?? note.stem
            func dest(_ ext: String) -> String { dir.path + "/" + stem + "." + ext }

            // What changed on the iPhone since it was last looked at. A file that's gone from there, or only a
            // placeholder now (iCloud made room), changes nothing here: nothing is deleted.
            var changed: [String] = []
            var coming = false
            for ext in PhoneImport.extensions {
                if let file = note.files[ext] {
                    if let old = rec.files[ext], old.size == file.size, old.mtime == file.mtime { continue }
                    changed.append(ext)
                } else if note.placeholders.contains(ext), rec.files[ext] == nil {
                    coming = true
                    PhoneImport.startDownload(note.dir.appendingPathComponent(note.stem + "." + ext))
                }
            }
            guard !changed.isEmpty else { return coming ? .waiting : .unchanged }

            // A file here is replaced only if it is still as it was copied. The .md and .json go together: if either
            // was edited here (a speaker renamed), neither is replaced. A note deleted here stays deleted.
            let deleted = rec.files["md"] != nil && !PhoneImport.exists(dest("md"))
            func intact(_ ext: String) -> Bool {
                guard let old = rec.files[ext] else { return !PhoneImport.exists(dest(ext)) }  // not copied before: the name is free
                return PhoneImport.sha256(ofFileAt: dest(ext)) == old.sha256
            }
            var allowed: [String] = []
            var blocked: [String] = []
            let text = changed.filter { $0 == "md" || $0 == "json" }
            if !text.isEmpty {
                if !deleted, intact("md"), intact("json") { allowed += text } else { blocked += text }
            }
            for ext in changed where ext != "md" && ext != "json" {
                if !deleted, intact(ext) { allowed.append(ext) } else { blocked.append(ext) }
            }

            var staged: [Staged] = []
            defer { for s in staged { unlink(s.temp.path) } }
            do {
                for ext in allowed { staged.append(try PhoneImport.stage(note.files[ext]!.url, ext: ext, in: dir)) }
            } catch {
                failed(error)
                for ext in changed { PhoneImport.startDownload(note.dir.appendingPathComponent(note.stem + "." + ext)) }
                return .waiting
            }

            var written = 0
            do {
                for s in staged.sorted(by: { PhoneImport.rank($0.ext) < PhoneImport.rank($1.ext) }) {
                    if rec.files[s.ext]?.sha256 == s.file.sha256 {
                        rec.files[s.ext] = s.file  // the same bytes; only the file's date moved
                    } else {
                        try PhoneImport.move(s.temp, to: URL(fileURLWithPath: dest(s.ext)))
                        rec.files[s.ext] = s.file
                        written += 1
                        if s.ext == "md", let sha = PhoneImport.addMacTitle(for: note, to: URL(fileURLWithPath: dest("md"))) {
                            rec.files["md"]?.sha256 = sha
                        }
                    }
                }
            } catch {
                failed(error)
                return .waiting
            }

            // Left as they are here: remember the iPhone's version was seen, so it isn't looked at again every minute.
            for ext in blocked {
                guard let file = note.files[ext] else { continue }
                rec.files[ext] = State.File(size: file.size, mtime: file.mtime, sha256: rec.files[ext]?.sha256 ?? "")
            }
            // This Mac's copy was edited here, so it stays, but what the iPhone added to the note since (its place,
            // Keep audio, its AI title) still says something true about it: those lines are brought over. It stays
            // an edited copy (the list keeps the hash it was copied with), so nothing else is ever replaced.
            if blocked.contains("md"), !deleted, let file = note.files["md"] {
                do {
                    if try PhoneImport.mergeLaterKeys(from: file.url, into: URL(fileURLWithPath: dest("md"))) { written += 1 }
                } catch {
                    failed(error)
                }
            }
            if !blocked.isEmpty { keptNow += 1 }
            if written > 0 { return .updated }
            if !blocked.isEmpty { return .kept }
            return coming ? .waiting : .unchanged
        }
    }

    // MARK: what the iPhone and this Mac add to a note later

    /// A title this Mac made for one of the iPhone's notes (`MacTitles`), put into this Mac's copy now rather than when
    /// the iPhone next folds it in (the iPhone only does that while Sona is open there). Only into a copy that is
    /// still as it was copied and has no `ai_title`; the list then keeps the titled copy as the one copied, so the
    /// iPhone's next change to the note still replaces it. False if it wasn't added (another import is running, the
    /// note isn't on the list, or its copy here was edited, deleted or already has a title). Blocking.
    @discardableResult
    public static func addTitle(_ title: String, day: String, stem: String, to conversations: URL, statePath: URL) -> Bool {
        guard let lock = Lock.acquire(statePath.path + ".lock") else { return false }
        defer { lock.release() }
        var state = loadState(statePath, log: { _ in })
        let id = day + "/" + stem
        guard state.destination == conversations.standardizedFileURL.path, var rec = state.notes[id],
            let copied = rec.files["md"]
        else { return false }
        let url = conversations.appendingPathComponent(day, isDirectory: true)
            .appendingPathComponent((rec.stem ?? stem) + ".md")
        guard sha256(ofFileAt: url.path) == copied.sha256, let sha = try? addAITitle(title, to: url) else { return false }
        rec.files["md"]?.sha256 = sha
        state.notes[id] = rec
        // Unsaved, the copy would look edited here and the iPhone's later changes would never replace it: put the
        // note back as it was.
        do { try saveState(state, to: statePath) } catch {
            try? NoteFrontMatter.update(fileAt: url, set: ["ai_title": nil])
            return false
        }
        return true
    }

    /// This Mac's title for `note`, from the titles file beside the iPhone's folder it came from, put into the copy
    /// just written at `url` if that has no `ai_title`. The copy's new hash, or nil if nothing was added.
    private static func addMacTitle(for note: SourceNote, to url: URL) -> String? {
        let file = TitlesFile.url(forConversations: note.dir.deletingLastPathComponent(), day: note.day)
        guard let data = try? Data(contentsOf: file), let title = TitlesFile.decode(data)?.titles[note.stem] else {
            return nil
        }
        return try? addAITitle(title, to: url)
    }

    /// `title` as the note's `ai_title`, if it has none (or a blank one) and it reads as a title (the titles file is in
    /// iCloud Drive, so it's checked like the iPhone checks it). The file's new hash; nil if nothing changed.
    private static func addAITitle(_ title: String, to url: URL) throws -> String? {
        let title = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard TitleText.isAcceptable(title) else { return nil }
        let text = try String(contentsOf: url, encoding: .utf8)
        let has = NoteStore.splitFrontmatter(text).0["ai_title"]?.trimmingCharacters(in: .whitespaces).isEmpty == false
        guard !has, NoteFrontMatter.update(text, set: ["ai_title": title]) != text else { return nil }
        try NoteFrontMatter.update(fileAt: url, set: ["ai_title": title])
        return sha256(ofFileAt: url.path)
    }

    /// The keys the iPhone adds to a note after writing it (`NoteStore.addedLater`), as its copy at `phone` has them
    /// now, set the same in this Mac's copy at `mac` (one edited here): added, changed, or removed (Keep audio turned
    /// off). `ai_title` is only added or changed, never removed, and only while this Mac's copy has as many transcript
    /// lines as the iPhone's: one cut here ("delete the last N minutes") lost words the title may describe. True if
    /// this Mac's copy changed.
    static func mergeLaterKeys(from phone: URL, into mac: URL) throws -> Bool {
        let theirs = try String(contentsOf: phone, encoding: .utf8)
        let ours = try String(contentsOf: mac, encoding: .utf8)
        let changes = laterKeys(phone: theirs, mac: ours)
        guard NoteFrontMatter.update(ours, set: changes) != ours else { return false }
        try NoteFrontMatter.update(fileAt: mac, set: changes)
        return true
    }

    /// What `mergeLaterKeys` sets: each key's value in the iPhone's note, nil where it has none.
    static func laterKeys(phone: String, mac: String) -> [String: String?] {
        func lines(_ text: String) -> Int {
            NoteStore.splitFrontmatter(text).1.split(separator: "\n").filter { NoteStore.parseLine(String($0)) != nil }.count
        }
        let front = NoteStore.splitFrontmatter(phone).0
        func value(_ key: String) -> String? {
            front[key].flatMap { $0.trimmingCharacters(in: .whitespaces).isEmpty ? nil : $0 }
        }
        var out: [String: String?] = [:]
        for key in NoteStore.keptOnCut { out[key] = .some(value(key)) }
        // Never taken away: a title this Mac gave its copy stays until the iPhone has one.
        if let title = value("ai_title"), lines(phone) == lines(mac) { out["ai_title"] = .some(title) }
        return out
    }

    // MARK: copying

    private struct Staged {
        var ext: String
        var temp: URL
        var file: State.File
    }

    private enum CopyError: LogSafeError { case notAFile, changedWhileCopying }

    /// What a copy is called while it is being written, hidden in the day folder it is going to: a dot, 8 hex digits
    /// (a UUID's first 8 characters) and this ending. A kill or a power cut before it is moved into place leaves it.
    private static let tempSuffix = ".phone-import.tmp"

    static func tempName() -> String { ".\(UUID().uuidString.prefix(8))\(tempSuffix)" }

    /// Only this importer's own temp names, and nothing else.
    static func isTempName(_ name: String) -> Bool {
        let bytes = Array(name.utf8)
        guard bytes.count == 1 + 8 + tempSuffix.utf8.count, bytes[0] == UInt8(ascii: "."), name.hasSuffix(tempSuffix) else { return false }
        return bytes[1...8].allSatisfy { ($0 >= UInt8(ascii: "0") && $0 <= UInt8(ascii: "9")) || ($0 >= UInt8(ascii: "A") && $0 <= UInt8(ascii: "F")) }
    }

    /// A temp file nobody has written to for this long belongs to a copy that was stopped, not one going on now.
    private static let staleTempAge: TimeInterval = 5 * 60

    /// Removes the temp files that copies stopped halfway (a kill, a power cut) left in the day folders of
    /// `conversations`, where they would sit hidden and take up room for good. Only this importer's own temp names,
    /// only plain files, and only ones not written to for `staleTempAge`; nothing else in a notes folder, and nothing
    /// in the iPhone's folders. Costs a listing of each day folder here and a stat per temp-named file.
    private static func clearLeftovers(in conversations: URL, log: (String) -> Void) {
        let cutoff = Int64((Date().timeIntervalSince1970 - staleTempAge) * 1_000_000_000)
        var removed = 0
        for day in SearchIndex.entries(conversations.path) where SearchIndex.isDay(day) {
            let dirPath = conversations.path + "/" + day
            guard NoteWriter.isRealDirectory(dirPath) else { continue }
            for name in SearchIndex.entries(dirPath) where isTempName(name) {
                let path = dirPath + "/" + name
                var st = stat()
                guard lstat(path, &st) == 0, (st.st_mode & S_IFMT) == S_IFREG, nanoseconds(st) < cutoff else { continue }
                if unlink(path) == 0 { removed += 1 }
            }
        }
        if removed > 0 {
            log("phone import: cleared \(removed) half-copied file\(removed == 1 ? "" : "s") left by an import that was stopped")
        }
    }

    /// The iPhone's file copied to a hidden temp file in `dir` (0600, so it moves into place whole), hashed on the way.
    /// It's read through one open file, so what's hashed is what's copied; if the file changed meanwhile it's dropped
    /// and the next run takes it again. A read that fails (iCloud hasn't downloaded it) throws.
    private static func stage(_ source: URL, ext: String, in dir: URL) throws -> Staged {
        let input = open(source.path, O_RDONLY | O_NOFOLLOW)
        guard input >= 0 else { throw NoteWriter.posixError() }
        defer { close(input) }
        var before = stat()
        guard fstat(input, &before) == 0, (before.st_mode & S_IFMT) == S_IFREG else { throw CopyError.notAFile }

        let temp = dir.appendingPathComponent(tempName())
        let output = open(temp.path, O_WRONLY | O_CREAT | O_EXCL, 0o600)
        guard output >= 0 else { throw NoteWriter.posixError() }
        fchmod(output, 0o600)
        var keep = false
        defer {
            close(output)
            if !keep { unlink(temp.path) }
        }

        var hasher = SHA256()
        var buffer = [UInt8](repeating: 0, count: 256 * 1024)
        let capacity = buffer.count
        var total: Int64 = 0
        while true {
            let n = read(input, &buffer, capacity)
            if n < 0 {
                if errno == EINTR { continue }
                throw NoteWriter.posixError()
            }
            if n == 0 { break }
            buffer.withUnsafeBytes { hasher.update(bufferPointer: UnsafeRawBufferPointer(rebasing: $0[0..<n])) }
            var done = 0
            while done < n {
                let w = buffer.withUnsafeBytes { Darwin.write(output, $0.baseAddress! + done, n - done) }
                if w < 0 {
                    if errno == EINTR { continue }
                    throw NoteWriter.posixError()
                }
                done += w
            }
            total += Int64(n)
        }
        var after = stat()
        guard fstat(input, &after) == 0, Int64(after.st_size) == total, Int64(after.st_size) == Int64(before.st_size),
            nanoseconds(after) == nanoseconds(before)
        else { throw CopyError.changedWhileCopying }
        keep = true
        return Staged(ext: ext, temp: temp, file: State.File(size: total, mtime: nanoseconds(after), sha256: hex(hasher.finalize())))
    }

    private static func rank(_ ext: String) -> Int { writeOrder.firstIndex(of: ext) ?? writeOrder.count }

    private static func move(_ temp: URL, to url: URL) throws { try NoteWriter.move(temp, to: url) }

    // MARK: files

    private static func nanoseconds(_ st: stat) -> Int64 {
        Int64(st.st_mtimespec.tv_sec) * 1_000_000_000 + Int64(st.st_mtimespec.tv_nsec)
    }

    private static func hex(_ digest: SHA256.Digest) -> String {
        digest.map { String(format: "%02x", $0) }.joined()
    }

    /// Nil if it can't be read (or is a symlink).
    private static func sha256(ofFileAt path: String) -> String? {
        let fd = open(path, O_RDONLY | O_NOFOLLOW)
        guard fd >= 0 else { return nil }
        defer { close(fd) }
        var hasher = SHA256()
        var buffer = [UInt8](repeating: 0, count: 256 * 1024)
        let capacity = buffer.count
        while true {
            let n = read(fd, &buffer, capacity)
            if n < 0 {
                if errno == EINTR { continue }
                return nil
            }
            if n == 0 { break }
            buffer.withUnsafeBytes { hasher.update(bufferPointer: UnsafeRawBufferPointer(rebasing: $0[0..<n])) }
        }
        return hex(hasher.finalize())
    }

    private static func exists(_ path: String) -> Bool {
        var st = stat()
        return lstat(path, &st) == 0
    }

    private static func isDirectory(_ path: String) -> Bool {
        var st = stat()
        return stat(path, &st) == 0 && (st.st_mode & S_IFMT) == S_IFDIR
    }

    private static func sameFolder(_ a: URL, _ b: URL) -> Bool {
        var x = stat(), y = stat()
        guard stat(a.path, &x) == 0, stat(b.path, &y) == 0 else { return false }
        return x.st_dev == y.st_dev && x.st_ino == y.st_ino
    }

    /// An advisory lock on a file, held until `release`.
    private struct Lock {
        let fd: Int32

        static func acquire(_ path: String) -> Lock? {
            let fd = open(path, O_RDWR | O_CREAT, 0o600)
            guard fd >= 0 else { return nil }
            guard flock(fd, LOCK_EX | LOCK_NB) == 0 else {
                close(fd)
                return nil
            }
            return Lock(fd: fd)
        }

        func release() { close(fd) }
    }
}
#endif
