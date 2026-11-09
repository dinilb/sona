import Foundation

/// One transcript line as it appears in a note: `[00:12] Speaker 1: ...`.
public struct NoteLine: Equatable, Sendable {
    /// Seconds from the conversation start.
    public var offset: Double
    public var clock: String
    public var speaker: String
    public var text: String
}

/// A conversation note read back from disk.
public struct ConversationNote: Sendable {
    /// Path under Conversations without `.md`, e.g. `2026-10-27/13-05 Budget for the March launch`.
    public var id: String
    public var url: URL
    public var title: String
    public var date: String
    public var start: String
    public var end: String
    public var duration: String
    public var speakers: [String]
    public var lines: [NoteLine]
    /// Why it's likely media (a video or podcast the Mac played), from the note's `media_reason`; nil for talk.
    public var media: String? = nil
    /// The audio file it was made from (`sona file`); nil for what the mic heard.
    public var source: String? = nil
    /// A title the on-device model gave it (`ai_title`). `title`, the heading and the file name keep the first-words
    /// title; lists show `displayTitle`.
    public var aiTitle: String? = nil
    /// Where it was recorded: a short street name (`place`) and "lat,lon" (`geo`), from when it started.
    public var place: String? = nil
    public var geo: String? = nil
    /// Where it stopped (`place_end`, `geo_end`), only when that's well away from where it started.
    public var placeEnd: String? = nil
    public var geoEnd: String? = nil
    /// Keep audio (`keep_audio: true`): its audio stays for good, whatever the iPhone's audio setting.
    public var keepAudio: Bool = false

    /// The title to show: the AI title when it has one, else `title`.
    public var displayTitle: String {
        if let aiTitle, !aiTitle.trimmingCharacters(in: .whitespaces).isEmpty { return aiTitle }
        return title
    }

    /// The device that recorded it, "iPhone" or "Apple Watch"; nil for this Mac's own notes and audio files.
    public var recordedOn: String? { NoteSource.isDeliberate(source) ? source : nil }

    /// Where it was recorded, for a list or a header: "4 Main St", or "4 Main St → 10 Queen St" when it stopped
    /// somewhere else. Nil without a place.
    public var placeText: String? {
        switch (place, placeEnd) {
        case let (start?, end?) where start != end: return "\(start) → \(end)"
        case let (start?, _): return start
        case let (nil, end?): return end
        case (nil, nil): return nil
        }
    }

    public var startedAt: Date? { startedAt(in: .current) }

    public var endedAt: Date? { endedAt(in: .current) }

    /// Its header's times are local time where it was written: in `zone`, if that's known (its .json says).
    func startedAt(in zone: TimeZone) -> Date? { Self.parse(date, start, zone: zone) }

    func endedAt(in zone: TimeZone) -> Date? {
        guard let s = startedAt(in: zone), var e = Self.parse(date, end, zone: zone) else { return nil }
        if e < s { e = e.addingTimeInterval(86_400) }  // ran past midnight
        return e
    }

    /// Wall-clock time of a line, "14:03:12".
    public func wallClock(_ line: NoteLine) -> String {
        guard let s = startedAt else { return line.clock }
        return NoteWriter.timeString(s.addingTimeInterval(line.offset), "HH:mm:ss")
    }

    public static func parse(_ date: String, _ time: String, zone: TimeZone = .current) -> Date? {
        NoteWriter.formatter(time.count > 5 ? "yyyy-MM-dd HH:mm:ss" : "yyyy-MM-dd HH:mm", zone: zone).date(from: "\(date) \(time)")
    }
}

/// A conversation as its file name tells it (for lists; open the note for the rest).
public struct NoteName: Hashable, Identifiable, Sendable {
    /// `2026-10-27/14-03 Budget for the March launch`, like `ConversationNote.id`.
    public var id: String
    public var day: String
    /// `14:03`.
    public var time: String
    /// The title as it appears in the file name (a few characters like `:` or `?` become spaces there).
    public var title: String
}

public enum NoteStoreError: Error, CustomStringConvertible {
    case notFound(String)
    case ambiguous(String, [String])
    case badName(String)
    case speakerNotFound(String, [String])
    /// The note changed on disk while it was being edited (written again, cut by "delete the last N minutes").
    case changed(String)

    public var description: String {
        switch self {
        case .notFound(let id): return "No conversation matches \"\(id)\". Use list_conversations or search to find ids."
        case .ambiguous(let id, let ids):
            return "\"\(id)\" matches \(ids.count) conversations: \(ids.prefix(10).joined(separator: "; ")). Pass the full id."
        case .badName(let why): return why
        case .speakerNotFound(let name, let have):
            return "No speaker called \"\(name)\" in that conversation. Speakers: \(have.joined(separator: ", "))."
        case .changed(let id):
            return "\"\(id)\" changed while it was being renamed, so nothing was written. Read it again, then retry."
        }
    }
}

/// Reads and edits the markdown notes in `<notes>/Conversations`. Plain file scans: fast enough for years
/// of notes, and the files stay the only source of truth (nothing to get out of sync).
///
/// The exception is `search`, which goes through a SQLite FTS5 index when the store has one (`index`), a cache in the support folder
/// that resyncs from the files on every search. Without one, or if the index fails, it scans the files.
public struct NoteStore {
    public let root: URL
    /// The full-text index for `search`, or nil to scan the files.
    public private(set) var index: SearchIndex?

    /// `indexURL`: where to keep the search index; nil scans the files on every search.
    public init(root: URL, indexURL: URL? = nil) {
        self.root = root
        if let indexURL { index = SearchIndex(url: indexURL, store: NoteStore(root: root)) }
    }

    public init(settings: Settings = .load()) {
        self.init(root: settings.conversationsURL, indexURL: Paths.searchIndex)
        index?.onError = { Log.note($0) }
    }

    /// Day folders (`YYYY-MM-DD`) between `from` and `to` inclusive, oldest first.
    public func days(from: String? = nil, to: String? = nil) -> [String] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: root.path)) ?? []
        return names.filter { name in
            guard name.count == 10, name.range(of: #"^\d{4}-\d{2}-\d{2}$"#, options: .regularExpression) != nil
            else { return false }
            if let from, name < from { return false }
            if let to, name > to { return false }
            return true
        }.sorted()
    }

    /// Every conversation in the date range, oldest first.
    public func conversations(from: String? = nil, to: String? = nil) -> [ConversationNote] {
        notes(from: from, to: to) { try read(url: $0) }
    }

    /// Every conversation's header in the date range (`lines` empty), oldest first: for lists. Only the start of each
    /// file is read, so a long transcript costs nothing here (the iPhone's list runs this on every refresh).
    public func headers(from: String? = nil, to: String? = nil) -> [ConversationNote] {
        notes(from: from, to: to) { try readHeader(url: $0) }
    }

    /// A note's header alone, from the first 8 KB (front matter is a few hundred bytes); the whole note if its front
    /// matter runs longer than that.
    public func readHeader(url: URL) throws -> ConversationNote {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let text = String(decoding: try handle.read(upToCount: 8192) ?? Data(), as: UTF8.self)
        let (front, _) = Self.splitFrontmatter(text)
        guard !front.isEmpty else {
            var note = try read(url: url)
            note.lines = []
            return note
        }
        return note(url: url, front: front, lines: [])
    }

    private func notes(from: String?, to: String?, reading: (URL) throws -> ConversationNote) -> [ConversationNote] {
        var out: [ConversationNote] = []
        for day in days(from: from, to: to) {
            let dir = root.appendingPathComponent(day, isDirectory: true)
            // Like the search index: no hidden files (macOS `._` AppleDouble copies) and no symlinks.
            let files = ((try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? [])
                .filter { name in
                    var st = stat()
                    return name.hasSuffix(".md") && !name.hasPrefix(".")
                        && lstat(dir.path + "/" + name, &st) == 0 && (st.st_mode & S_IFMT) == S_IFREG
                }.sorted()
            for file in files {
                if let note = try? reading(dir.appendingPathComponent(file)) { out.append(note) }
            }
        }
        return out.sorted { ($0.startedAt ?? .distantPast, $0.id) < ($1.startedAt ?? .distantPast, $1.id) }
    }

    /// Every conversation, newest first, from folder and file names alone (`YYYY-MM-DD/HH-MM Title.md`): no note
    /// is opened, so years of notes list in milliseconds. Same files as `conversations` (no hidden files or symlinks).
    public func names() -> [NoteName] {
        var out: [NoteName] = []
        for day in days().reversed() {
            let dir = root.appendingPathComponent(day, isDirectory: true)
            let files = ((try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []).filter { name in
                var st = stat()
                return name.hasSuffix(".md") && !name.hasPrefix(".")
                    && lstat(dir.path + "/" + name, &st) == 0 && (st.st_mode & S_IFMT) == S_IFREG
            }
            for file in files.sorted(by: >) {
                let stem = String(file.dropLast(3))
                let clock = stem.prefix(5)
                let isTime = clock.count == 5 && clock.dropFirst(2).first == "-"
                    && clock.replacingOccurrences(of: "-", with: "").allSatisfy(\.isNumber)
                let title = isTime ? String(stem.dropFirst(5)).trimmingCharacters(in: .whitespaces) : stem
                out.append(NoteName(
                    id: "\(day)/\(stem)", day: day, time: isTime ? clock.replacingOccurrences(of: "-", with: ":") : "",
                    title: title.isEmpty ? "Conversation" : title))
            }
        }
        return out
    }

    /// The most recent conversations, newest first.
    public func latest(_ count: Int) -> [ConversationNote] {
        var out: [ConversationNote] = []
        for day in days().reversed() {
            out.append(contentsOf: conversations(from: day, to: day).reversed())
            if out.count >= count { break }
        }
        return Array(out.prefix(count))
    }

    /// Accepts a full id, an id with `.md`, a path to the note, or a unique prefix like `2026-10-27/13-05`.
    /// Not `strict` (reads): also any unique case-insensitive part of an id. `strict` (writes): only an exact
    /// id or path, or a unique `YYYY-MM-DD/HH-mm` prefix, so a loose word can't edit the wrong note.
    public func resolve(_ id: String, strict: Bool = false) throws -> URL {
        var key = id.trimmingCharacters(in: .whitespacesAndNewlines)
        // Only notes inside the Conversations folder, never any other file on the Mac.
        if key.hasPrefix("/") || key.hasPrefix("~") {
            let url = URL(fileURLWithPath: (key as NSString).expandingTildeInPath).standardizedFileURL
            if url.pathExtension == "md", url.path.hasPrefix(root.standardizedFileURL.path + "/"),
                FileManager.default.fileExists(atPath: url.path)
            {
                return url
            }
            throw NoteStoreError.notFound(id)
        }
        guard !key.contains("..") else { throw NoteStoreError.notFound(id) }
        if key.hasSuffix(".md") { key = String(key.dropLast(3)) }
        let exact = root.appendingPathComponent(key + ".md")
        if FileManager.default.fileExists(atPath: exact.path) { return exact }
        if strict, key.range(of: #"^\d{4}-\d{2}-\d{2}/\d{2}-\d{2}$"#, options: .regularExpression) == nil {
            throw NoteStoreError.notFound(id)
        }

        let day = String(key.prefix(10))
        let searchDays = days().contains(day) ? [day] : days()
        var matches: [String] = []
        for d in searchDays {
            let dir = root.appendingPathComponent(d, isDirectory: true)
            for file in (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? [] where file.hasSuffix(".md") {
                let candidate = "\(d)/\(file.dropLast(3))"
                if candidate.hasPrefix(key) || (!strict && candidate.localizedCaseInsensitiveContains(key)) {
                    matches.append(candidate)
                }
            }
        }
        if matches.count == 1 { return root.appendingPathComponent(matches[0] + ".md") }
        if matches.isEmpty { throw NoteStoreError.notFound(id) }
        throw NoteStoreError.ambiguous(id, matches.sorted())
    }

    public func read(_ id: String) throws -> ConversationNote {
        try read(url: try resolve(id))
    }

    public func read(url: URL) throws -> ConversationNote {
        let text = try String(contentsOf: url, encoding: .utf8)
        let (front, body) = Self.splitFrontmatter(text)
        var lines: [NoteLine] = []
        for raw in body.split(separator: "\n", omittingEmptySubsequences: true) {
            if let line = Self.parseLine(String(raw)) { lines.append(line) }
        }
        return note(url: url, front: front, lines: lines)
    }

    private func note(url: URL, front: [String: String], lines: [NoteLine]) -> ConversationNote {
        let id = Self.relativeID(url, root: root)
        return ConversationNote(
            id: id, url: url,
            title: front["title"] ?? url.deletingPathExtension().lastPathComponent,
            date: front["date"] ?? String(id.prefix(10)),
            start: front["start"] ?? "",
            end: front["end"] ?? "",
            duration: front["duration"] ?? "",
            speakers: Self.parseList(front["speakers"] ?? ""),
            lines: lines,
            media: front["media"] == "true" ? (front["media_reason"] ?? "marked as media") : nil,
            source: front["source"],
            aiTitle: Self.value(front, "ai_title"),
            place: Self.value(front, "place"),
            geo: Self.value(front, "geo"),
            placeEnd: Self.value(front, "place_end"),
            geoEnd: Self.value(front, "geo_end"),
            keepAudio: front["keep_audio"] == "true")
    }

    /// A front-matter value as it's written (unquoted, like `title`), nil when it's missing or blank: a blank place or
    /// AI title is none.
    private static func value(_ front: [String: String], _ key: String) -> String? {
        guard let value = front[key], !value.trimmingCharacters(in: .whitespaces).isEmpty else { return nil }
        return value
    }

    public struct Hit: Sendable {
        public var note: ConversationNote
        public var line: NoteLine
    }

    /// Lines containing every word of `query` anywhere (case and accent insensitive, like the file scan),
    /// best match first (bm25), then newest. Uses the index when there is one; hits from it carry the note's
    /// metadata but not its `lines` (read the note for those).
    public func search(
        _ query: String, from: String? = nil, to: String? = nil, speaker: String? = nil, limit: Int = 30
    ) -> (hits: [Hit], total: Int) {
        if let index, let result = index.search(query, from: from, to: to, speaker: speaker, limit: limit) {
            return result
        }
        return scanSearch(query, from: from, to: to, speaker: speaker, limit: limit)
    }

    /// Conversations whose title (the AI title or the first-words one) or place has every word of `query` in it
    /// (case and accent insensitive, inside other words too, like `search`), newest first. Where the iPhone recorded
    /// a note is the user's own data on their own Mac, so it's searchable here; it's never logged. Uses the index's
    /// list of notes when there is one, else reads each note's header.
    public func notesMatching(_ query: String, from: String? = nil, to: String? = nil) -> [ConversationNote] {
        if let index, let found = index.notesMatching(query, from: from, to: to) { return found }
        let terms = Self.searchTerms(query)
        guard !terms.isEmpty else { return [] }
        return headers(from: from, to: to).reversed().filter { Self.matches($0, terms: terms) }
    }

    /// Every term is in the note's titles or places.
    static func matches(_ note: ConversationNote, terms: [String]) -> Bool {
        let haystack = [note.displayTitle, note.title, note.place ?? "", note.placeEnd ?? ""].joined(separator: "\n")
        return terms.allSatisfy { haystack.range(of: $0, options: [.caseInsensitive, .diacriticInsensitive]) != nil }
    }

    /// Words of a query, with quote marks around them dropped (AIs often quote what they look for).
    static func searchTerms(_ query: String) -> [String] {
        query.split(whereSeparator: \.isWhitespace)
            .map { $0.trimmingCharacters(in: CharacterSet(charactersIn: "\"'“”‘’")) }
            .filter { !$0.isEmpty }
    }

    /// The index-free search: reads every note in range. Lines containing every word of `query` as a
    /// substring (case and accent insensitive), newest conversation first.
    public func scanSearch(
        _ query: String, from: String? = nil, to: String? = nil, speaker: String? = nil, limit: Int = 30
    ) -> (hits: [Hit], total: Int) {
        let terms = Self.searchTerms(query)
        guard !terms.isEmpty else { return ([], 0) }
        let speakerKey = speaker.map(SearchIndex.speakerKey)  // case and accent insensitive, like the index
        var hits: [Hit] = []
        var total = 0
        for note in conversations(from: from, to: to).reversed() {
            for line in note.lines {
                if let speakerKey, SearchIndex.speakerKey(line.speaker) != speakerKey { continue }
                let haystack = line.speaker + ": " + line.text
                let all = terms.allSatisfy {
                    haystack.range(of: $0, options: [.caseInsensitive, .diacriticInsensitive]) != nil
                }
                guard all else { continue }
                total += 1
                if hits.count < limit { hits.append(Hit(note: note, line: line)) }
            }
        }
        return (hits, total)
    }

    /// Renames a speaker in one conversation: the note's lines and frontmatter, and the JSON sidecar.
    /// Renaming to a name already in the conversation merges the two. Returns how many lines changed.
    /// Nothing is written if the note or its .json changed on disk since they were read (`NoteStoreError.changed`):
    /// writing the old text back would undo that change, such as "delete the last N minutes" cutting the note.
    @discardableResult
    public func renameSpeaker(in id: String, from old: String, to new: String) throws -> Int {
        try renameSpeaker(in: id, from: old, to: new, afterReading: nil)
    }

    /// `afterReading`: tests change the note there, between the read and the write.
    @discardableResult
    func renameSpeaker(in id: String, from old: String, to new: String, afterReading: (() -> Void)?) throws -> Int {
        let name = new.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, name.count <= 60 else { throw NoteStoreError.badName("The new name must be 1-60 characters.") }
        guard name.rangeOfCharacter(from: CharacterSet(charactersIn: ":[],\\\n\r\"")) == nil else {
            throw NoteStoreError.badName("The new name can't contain : [ ] , \\ or quotes.")
        }
        let url = try resolve(id, strict: true)
        let json = url.deletingPathExtension().appendingPathExtension("json")
        // Stamped before reading, so a change at any point after shows.
        let stamps = (Self.stamp(url), Self.stamp(json))
        let note = try read(url: url)
        let lineSpeakers = Set(note.lines.map(\.speaker))
        guard let from = (note.speakers + Array(lineSpeakers)).first(where: { $0.caseInsensitiveCompare(old) == .orderedSame })
        else {
            throw NoteStoreError.speakerNotFound(old, note.speakers.isEmpty ? Array(lineSpeakers).sorted() : note.speakers)
        }

        let text = try String(contentsOf: url, encoding: .utf8)
        var changed = 0
        var inFront = false
        var frontDone = false
        var out: [String] = []
        for (i, raw) in text.components(separatedBy: "\n").enumerated() {
            var line = raw
            if i == 0, line == "---" {
                inFront = true
            } else if inFront, line == "---" {
                inFront = false
                frontDone = true
            } else if inFront, line.hasPrefix("speakers:") {
                var list = Self.parseList(String(line.dropFirst("speakers:".count)))
                list = list.map { $0 == from ? name : $0 }
                var unique: [String] = []
                for s in list where !unique.contains(s) { unique.append(s) }
                line = "speakers: [\(unique.map(NoteWriter.yamlString).joined(separator: ", "))]"
            } else if frontDone || !text.hasPrefix("---"), let parsed = Self.parseLine(line), parsed.speaker == from {
                line = "[\(parsed.clock)] \(name): \(parsed.text)"
                changed += 1
            }
            out.append(line)
        }
        let sidecar = (try? Data(contentsOf: json)).flatMap { try? JSONDecoder().decode(NoteWriter.Sidecar.self, from: $0) }
        afterReading?()
        guard Self.stamp(url) == stamps.0, Self.stamp(json) == stamps.1 else { throw NoteStoreError.changed(note.id) }
        try NoteWriter.writePrivate(Data(out.joined(separator: "\n").utf8), to: url)

        if var sidecar {
            for i in sidecar.words.indices where sidecar.words[i].speaker == from { sidecar.words[i].speaker = name }
            for i in sidecar.turns.indices where sidecar.turns[i].speaker == from { sidecar.turns[i].speaker = name }
            var unique: [String] = []
            for s in sidecar.speakers.map({ $0 == from ? name : $0 }) where !unique.contains(s) { unique.append(s) }
            sidecar.speakers = unique
            try NoteWriter.writeSidecar(sidecar, to: json)
        }
        return changed
    }

    /// A file's modification time, size and inode (nil: it isn't there), to tell whether it changed since it was read.
    struct Stamp: Equatable {
        var seconds: Int
        var nanoseconds: Int
        var size: Int64
        var inode: UInt64
    }

    static func stamp(_ url: URL) -> Stamp? {
        var st = stat()
        guard stat(url.path, &st) == 0 else { return nil }
        return Stamp(
            seconds: Int(st.st_mtimespec.tv_sec), nanoseconds: Int(st.st_mtimespec.tv_nsec), size: Int64(st.st_size),
            inode: UInt64(st.st_ino))
    }

    // MARK: delete the last minutes

    /// What `forget` did: notes deleted, notes cut, and notes it couldn't write again (they still have what was
    /// said then).
    public struct Forgotten: Equatable, Sendable {
        public var deleted = 0
        public var trimmed = 0
        public var failed = 0
        public var changed: Int { deleted + trimmed }
        public init() {}
    }

    /// "Delete the last N minutes": everything said from `cut` on goes. A note that started then or later is
    /// deleted (with its .json and any kept audio). A note that runs past `cut` is written again from its .json
    /// with only the words said before it, exactly as NoteWriter writes a note (so its title, and the file name,
    /// change if they came from those words). Its place and Keep audio stay; its AI title goes whenever any of its
    /// words do, since it may describe them. One edited by hand since (it's no longer what its .json makes), or
    /// without a readable .json, is cut by whole lines in the markdown instead (`cutLines`), the rest of it kept as
    /// it is. A note that can't be written again still has what was said then (its .json may be cut already), is
    /// counted in `failed`, and is never deleted to make up for it. Notes made from an audio file (`sona
    /// file`) carry the time they were made, not when it was said: they're never touched. Notes are private files
    /// like any other (0600), and the search index is the caller's to throw away.
    ///
    /// Times come from the .json (exact, with the UTC offset it was written with); the note's header is read in
    /// that time zone, or this Mac's without a .json. Looks at notes from 2 hours before `cut` on (a conversation is
    /// at most 75 minutes), in day folders up to 26 hours further back (each is named in its notes' time zone).
    @discardableResult
    public func forget(from cut: Date) -> Forgotten {
        var done = Forgotten()
        for note in conversations(from: NoteWriter.dayString(cut.addingTimeInterval(-28 * 3600))) {
            let json = Timed(note.url)
            // The Mac's, the iPhone's and the watch's recordings are cut by their real time; a note made from an audio
            // file isn't (its time is when it was transcribed).
            guard NoteSource.isLive(json?.side.source ?? note.source) else { continue }
            // The header is local time where the note was written: the .json's offset says where.
            let zone = json?.zone ?? .current
            guard let start = json?.start ?? note.startedAt(in: zone) else { continue }
            // The later end of the two: a note whose .json was cut, but that couldn't be written again itself, still
            // reaches the cut.
            let end = [json?.end, note.endedAt(in: zone)].compactMap { $0 }.max()
            // Note times are whole seconds: anything that may reach `cut` is looked at word by word.
            if start >= cut {
                if Self.remove(note.url) { done.deleted += 1 } else { done.failed += 1 }
            } else if (end ?? .distantFuture).addingTimeInterval(1) > cut {
                switch Self.trim(note, json, start: start, end: end, from: cut) {
                case .unchanged: break
                case .trimmed: done.trimmed += 1
                case .empty:
                    if Self.remove(note.url) { done.deleted += 1 } else { done.failed += 1 }
                case .failed: done.failed += 1
                }
            }
        }
        return done
    }

    enum Trim: Equatable { case unchanged, trimmed, empty, failed }

    /// Front-matter keys added after a note is written that say nothing of what was said: where it was recorded, and
    /// Keep audio. A cut keeps them. Not `ai_title`: it may describe what was cut, so a cut that takes words drops it.
    static let keptOnCut = ["place", "geo", "place_end", "geo_end", "keep_audio"]
    /// Keys NoteWriter never writes, added to a note later: having them doesn't make a note edited by hand.
    static let addedLater = Set(keptOnCut + ["ai_title"])

    /// A note's .json, read, with its start: exact, and the time zone it was written in.
    struct Timed {
        var side: NoteWriter.Sidecar
        var start: Date
        var zone: TimeZone
        var end: Date { start.addingTimeInterval(side.durationSeconds) }

        /// Nil without a .json next to `md`, or one that can't be read.
        init?(_ md: URL) {
            guard let data = try? Data(contentsOf: md.deletingPathExtension().appendingPathExtension("json")),
                let side = try? JSONDecoder().decode(NoteWriter.Sidecar.self, from: data),
                let start = ISO8601DateFormatter().date(from: side.startedAt)
            else { return nil }
            self.side = side
            self.start = start
            zone = NoteWriter.zone(ofISO: side.startedAt, at: start) ?? .current
        }

        /// Everything in it, as NoteWriter had it.
        var transcript: Transcript {
            Transcript(
                startedAt: start, duration: side.durationSeconds, text: side.text, words: side.words, turns: side.turns,
                asrSeconds: side.timing.asrSeconds, diarizationSeconds: side.timing.diarizationSeconds, model: side.model)
        }

        /// The .json for `t`, this one cut short.
        func sidecar(_ t: Transcript) -> NoteWriter.Sidecar {
            var side = side
            side.words = t.words
            side.turns = t.turns
            side.durationSeconds = (t.duration * 1000).rounded() / 1000
            side.text = t.text
            side.speakers = t.speakers
            return side
        }

        /// The note NoteWriter writes for `t`, in this note's time zone, and its title.
        func note(_ t: Transcript) -> (markdown: String, title: String) {
            let lines = Lines.from(t.words)
            let title = Title.make(from: lines) ?? "Conversation"
            let media = side.media == true ? (side.mediaReason ?? "marked as media") : nil
            return (NoteWriter.markdown(t, lines: lines, title: title, source: side.source, media: media, zone: zone), title)
        }
    }

    /// A note's new text and .json with nothing said from the cut on.
    struct Rewrite {
        /// Nil: the note itself stays as it is (it has no lines to cut); only its .json changes.
        var markdown: String?
        /// Nil: no .json (one that couldn't be read is out of step now, and goes).
        var sidecar: NoteWriter.Sidecar?
        var title: String
        var startedAt: Date
        var zone: TimeZone
    }

    enum Edit {
        case unchanged, empty
        /// Why it can't be cut (for the log: never what was said).
        case failed(String)
        case rewrite(Rewrite)
    }

    /// Writes the note again with only what was said before `cut`, renamed if its title changed. `start` and `end`:
    /// as `forget` worked them out.
    static func trim(_ note: ConversationNote, _ json: Timed?, start: Date, end: Date?, from cut: Date) -> Trim {
        let url = note.url
        var edit = Edit.failed("it can't be read")
        if let text = try? String(contentsOf: url, encoding: .utf8) {
            if let json, unedited(text, json.note(json.transcript).markdown) {
                edit = cutWords(json, from: cut, front: splitFrontmatter(text).0)
            } else {
                // No readable .json, or edited by hand since it was written: by whole lines, so the edits stay.
                edit = cutLines(note, text, json, start: start, end: end, from: cut)
            }
        }
        let new: Rewrite
        switch edit {
        case .unchanged: return .unchanged
        case .empty: return .empty
        case .failed(let why):
            Log.note("couldn't cut a note: \(why)")
            return .failed
        case .rewrite(let r): new = r
        }

        // Same file if the title (in the name) didn't change, "HH-MM <title> 2" included; else a new name.
        let stem = url.deletingPathExtension().lastPathComponent
        let wanted = NoteWriter.timeString(new.startedAt, "HH-mm", zone: new.zone) + " " + Title.fileSafe(new.title)
        let same =
            new.markdown == nil || stem == wanted
            || (stem.hasPrefix(wanted + " ") && Int(stem.dropFirst(wanted.count + 1)) != nil)
        var created: URL?
        var temps: [URL] = []
        defer { for tmp in temps { unlink(tmp.path) } }  // the ones never renamed into place
        do {
            let md = same ? url : try NoteWriter.createExclusively(in: url.deletingLastPathComponent(), stem: wanted)
            if !same { created = md }
            let sidecarURL = md.deletingPathExtension().appendingPathExtension("json")
            // Both go to temp files first, then into place: the .json, then the note. A failure before that changes
            // nothing; one between leaves the note as it was, its .json cut already.
            let mdTemp = try new.markdown.map { try NoteWriter.privateTemp(Data($0.utf8), for: md) }
            if let mdTemp { temps.append(mdTemp) }
            let sidecarTemp = try new.sidecar.map { try NoteWriter.privateTemp(try NoteWriter.sidecarData($0), for: sidecarURL) }
            if let sidecarTemp { temps.append(sidecarTemp) }
            if let sidecarTemp { try NoteWriter.move(sidecarTemp, to: sidecarURL) }
            if let mdTemp { try NoteWriter.move(mdTemp, to: md) }
            if same {
                // A .json that couldn't be read is out of step now, and kept audio (a test-only setting) isn't cut.
                if new.sidecar == nil { try? FileManager.default.removeItem(at: sidecarURL) }
                for audio in Self.keptAudio(of: url) { try? FileManager.default.removeItem(at: audio) }
            } else if !remove(url) {
                return .failed  // the cut note is in place, but the old one (or its .json or audio) still has it all
            }
            return .trimmed
        } catch {
            if let created { remove(created) }
            Log.note("couldn't cut a note: \(Log.describe(error))")
            return .failed
        }
    }

    /// Is `text` still the note NoteWriter wrote (`written`), not edited since? Its end and duration don't count:
    /// the .json's start has whole seconds, which can put them a second off, and a cut writes them again anyway. Nor do
    /// the keys added to a note after it's written (`addedLater`: its place, AI title, Keep audio).
    static func unedited(_ text: String, _ written: String) -> Bool {
        func compared(_ s: String) -> [Substring] {
            var inFront = false
            var out: [Substring] = []
            for (i, line) in s.split(separator: "\n", omittingEmptySubsequences: false).enumerated() {
                if line == "---", i == 0 || inFront {
                    inFront = i == 0
                } else if inFront, line.hasPrefix("end:") || line.hasPrefix("duration:") {
                    continue
                } else if inFront, let key = NoteFrontMatter.key(of: line), addedLater.contains(key) {
                    continue
                }
                out.append(line)
            }
            return out
        }
        return compared(text) == compared(written)
    }

    /// From the .json, word by word: exactly what NoteWriter writes for the words said before the cut, with the keys
    /// of `front` (the note's front matter) that a cut keeps (`keptOnCut`). Its AI title goes.
    static func cutWords(_ json: Timed, from cut: Date, front: [String: String] = [:]) -> Edit {
        let full = json.transcript
        // The saved start has whole seconds, up to 1 s before the real one: cut a second early rather than late.
        let t = full.cut(at: cut.timeIntervalSince(json.start) - 1)
        if t.words.count == full.words.count { return .unchanged }
        if t.words.isEmpty { return .empty }
        let written = json.note(t)
        var kept: [String: String?] = [:]
        for key in keptOnCut { if let value = front[key] { kept[key] = value } }
        let markdown = NoteFrontMatter.update(written.markdown, set: kept)
        return .rewrite(
            Rewrite(markdown: markdown, sidecar: json.sidecar(t), title: written.title, startedAt: json.start, zone: json.zone))
    }

    /// By whole lines of the markdown (`text`), for a note without a readable .json or one edited by hand. A line stays
    /// if the next one began before the cut (so it had ended), or if none of its .json words (from its time to the next
    /// line's) began from the cut on; without those words, the last one stays only if the note ended before the cut.
    /// The first line that doesn't stay goes with everything after it in the file, up to a "## " section of the user's
    /// own; the rest of the file stays as it is. Its end, duration and speakers follow what's left, and its title and
    /// heading do too unless they were set by hand; its AI title goes. Its
    /// .json (`json`), if it has one, loses the words said from the cut on (never more), and ends before it.
    static func cutLines(_ note: ConversationNote, _ text: String, _ json: Timed?, start: Date, end: Date?, from cut: Date) -> Edit {
        let zone = json?.zone ?? .current
        // Never past the .json's end: an earlier cut that couldn't write the note again cut the .json there already.
        let keep = min(cut.timeIntervalSince(start) - 1, json?.side.durationSeconds ?? .infinity)
        // Its words say when each line ended only if it has them all: it reaches the note's end (an earlier cut didn't
        // shorten it).
        let words = json.flatMap { json in json.end.addingTimeInterval(1) >= (end ?? json.end) ? json.side.words : nil }
        let side = json.map { json in
            var side = json.sidecar(json.transcript.cut(at: keep))
            side.durationSeconds = min(side.durationSeconds, max(0, (keep * 1000).rounded(.down) / 1000))
            return side
        }
        let lines = note.lines
        let ended = end.map { $0.addingTimeInterval(1) <= cut } ?? false
        let kept = lines.indices.prefix { i in
            let next = i + 1 < lines.count ? lines[i + 1].offset : nil
            if let next, next <= keep { return true }
            guard let words else { return next == nil && ended }
            // One that runs over the cut goes, all of it (its words from before stay in the .json): hand-edited text
            // can't be split safely, and nothing said from the cut on may stay.
            return lines[i].offset < keep && !words.contains { $0.start >= max(lines[i].offset, keep) && $0.start < (next ?? .infinity) }
        }.count
        // Nothing left of what was said: deleted, but never while its .json has words from before the cut.
        if kept == 0, !lines.isEmpty, side?.words.isEmpty ?? true { return .empty }
        if kept == lines.count {
            // No line to cut (it has none, or they all ended before the cut), but its .json may have words from then.
            guard let json, let side else { return .unchanged }
            // Words from then that no line shows (their times taken out by hand, say): the note can't be cut safely.
            if side.words.count < json.side.words.count { return .failed("its .json has words from then that no timed line shows") }
            guard side.durationSeconds < json.side.durationSeconds else { return .unchanged }
            return .rewrite(Rewrite(markdown: nil, sidecar: side, title: note.title, startedAt: start, zone: zone))
        }
        let left = lines.prefix(kept)
        func made(from lines: ArraySlice<NoteLine>) -> String {
            Title.make(from: lines.map { Line(speaker: $0.speaker, start: $0.offset, end: $0.offset, text: $0.text) }) ?? "Conversation"
        }
        // A title (or heading) set by hand stays. One made from its lines (or from the .json's words, as written) is
        // made again from what's left, since it may come from what was said from the cut on.
        let autoTitles = [made(from: lines[...])] + (json.map { [$0.note($0.transcript).title] } ?? [])
        let remade = made(from: left)
        let auto = autoTitles.contains(note.title)
        let title = auto ? remade : note.title
        let duration = max(0, min(lines[kept].offset, keep))
        var speakers: [String] = []
        for line in left where !speakers.contains(line.speaker) { speakers.append(line.speaker) }

        var out: [String] = []
        var inFront = false, heading = false, dropping = false
        var index = 0  // of the transcript line, as `read` counts them
        for (n, raw) in text.components(separatedBy: "\n").enumerated() {
            if n == 0, raw == "---" {
                inFront = true
            } else if inFront {
                if raw == "---" {
                    inFront = false
                } else if NoteFrontMatter.key(of: raw) == "ai_title" {
                    continue  // it may describe what was cut
                } else if raw.hasPrefix("title:"), auto {
                    out.append("title: \(NoteWriter.yamlString(title))")
                    continue
                } else if raw.hasPrefix("end:") {
                    out.append("end: \"\(NoteWriter.timeString(start.addingTimeInterval(duration), "HH:mm:ss", zone: zone))\"")
                    continue
                } else if raw.hasPrefix("duration:") {
                    out.append("duration: \(Lines.durationText(duration))")
                    continue
                } else if raw.hasPrefix("speakers:") {
                    out.append("speakers: [\(speakers.map(NoteWriter.yamlString).joined(separator: ", "))]")
                    continue
                }
            } else if !heading, raw.hasPrefix("# ") {
                heading = true
                if autoTitles.contains(String(raw.dropFirst(2))) {
                    out.append("# \(remade)")
                    continue
                }
            } else if parseLine(raw) != nil {
                index += 1
                // A line that goes takes the text after it that isn't a timed line (it may be part of it), up to a
                // "## " heading: a section of the user's own.
                dropping = index > kept
                if dropping { continue }
            } else if dropping {
                guard raw.hasPrefix("## ") else { continue }
                dropping = false
            }
            out.append(raw)
        }
        while out.last == "" { out.removeLast() }
        out.append("")  // one newline at the end, like NoteWriter's
        return .rewrite(Rewrite(markdown: out.joined(separator: "\n"), sidecar: side, title: title, startedAt: start, zone: zone))
    }

    /// A note's own files: the note, its .json and its kept audio. Deleting a note deletes all of them.
    public static func files(of url: URL) -> [URL] {
        [url, url.deletingPathExtension().appendingPathExtension("json")] + keptAudio(of: url)
    }

    /// A note's kept audio: the room's and what this Mac played (a test-only setting), and the iPhone's recording
    /// (`.m4a`, copied over by `PhoneImport`), so deleting a note never leaves its audio behind.
    static func keptAudio(of url: URL) -> [URL] {
        let base = url.deletingPathExtension()
        return [base.appendingPathExtension("wav"), base.appendingPathExtension("mac.wav"), base.appendingPathExtension("m4a")]
    }

    /// A note, its .json and its kept audio, deleted for good. False (and logged) if any of them is still there.
    @discardableResult
    static func remove(_ url: URL) -> Bool {
        let files = files(of: url)
        for file in files { try? FileManager.default.removeItem(at: file) }
        guard files.contains(where: { FileManager.default.fileExists(atPath: $0.path) }) else { return true }
        Log.note("couldn't delete a note's files")
        return false
    }

    // MARK: parsing

    static func relativeID(_ url: URL, root: URL) -> String {
        let path = url.deletingPathExtension().standardizedFileURL.path
        let base = root.standardizedFileURL.path + "/"
        return path.hasPrefix(base) ? String(path.dropFirst(base.count)) : url.deletingPathExtension().lastPathComponent
    }

    static func splitFrontmatter(_ text: String) -> ([String: String], Substring) {
        guard text.hasPrefix("---\n") else { return ([:], Substring(text)) }
        let afterOpen = text.index(text.startIndex, offsetBy: 4)
        guard let close = text.range(of: "\n---", range: afterOpen..<text.endIndex) else { return ([:], Substring(text)) }
        var front: [String: String] = [:]
        for raw in text[afterOpen..<close.lowerBound].split(separator: "\n") {
            guard let colon = raw.firstIndex(of: ":") else { continue }
            let key = raw[..<colon].trimmingCharacters(in: .whitespaces)
            var value = raw[raw.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            if value.count >= 2, value.hasPrefix("\""), value.hasSuffix("\"") {
                value = String(value.dropFirst().dropLast()).replacingOccurrences(of: "\\\"", with: "\"")
                    .replacingOccurrences(of: "\\\\", with: "\\")
            }
            front[key] = value
        }
        return (front, text[close.upperBound...])
    }

    /// `["Speaker 1", "Alex"]` or `[a, b]`.
    static func parseList(_ raw: String) -> [String] {
        var s = raw.trimmingCharacters(in: .whitespaces)
        if s.hasPrefix("[") { s.removeFirst() }
        if s.hasSuffix("]") { s.removeLast() }
        return s.split(separator: ",").map {
            var item = $0.trimmingCharacters(in: .whitespaces)
            if item.count >= 2, item.hasPrefix("\""), item.hasSuffix("\"") { item = String(item.dropFirst().dropLast()) }
            return item
        }.filter { !$0.isEmpty }
    }

    /// `[00:12] Speaker 1: text` or `[1:02:03] Alex: text`.
    static func parseLine(_ raw: String) -> NoteLine? {
        guard raw.hasPrefix("["), let close = raw.firstIndex(of: "]") else { return nil }
        let clock = String(raw[raw.index(after: raw.startIndex)..<close])
        let parts = clock.split(separator: ":").compactMap { Int($0) }
        guard parts.count == clock.split(separator: ":").count, (2...3).contains(parts.count) else { return nil }
        let offset = Double(parts.reduce(0) { $0 * 60 + $1 })
        let rest = raw[raw.index(after: close)...].drop(while: { $0 == " " })
        guard let colon = rest.range(of: ": ") else { return nil }
        let speaker = String(rest[..<colon.lowerBound])
        guard !speaker.isEmpty, speaker.count <= 60 else { return nil }
        return NoteLine(offset: offset, clock: clock, speaker: speaker, text: String(rest[colon.upperBound...]))
    }
}
