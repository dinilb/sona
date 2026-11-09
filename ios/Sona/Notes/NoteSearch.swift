import Foundation
import NotesKit

/// Home's search: a row matches when every word typed is somewhere in its title, its places, "from watch" or what was
/// said, one word in the title and another in the words is fine. The first three are on the row already; what was
/// said is read off the main thread (`TranscriptCache`).
nonisolated enum NoteSearch {
    /// Every word of `query` appears somewhere in `fields` (case and accent insensitive, inside other words too, like
    /// the Mac's search). An empty query matches everything.
    static func matches(_ query: String, in fields: [String]) -> Bool {
        let words = query.split(whereSeparator: \.isWhitespace)
        guard !words.isEmpty else { return true }
        let text = fields.joined(separator: "\n")
        return words.allSatisfy { text.range(of: $0, options: [.caseInsensitive, .diacriticInsensitive]) != nil }
    }

    /// What a row offers without reading its note: title, places, and where it came from.
    static func fields(_ row: NoteRow) -> [String] {
        [row.title] + row.places + (row.isWatch ? [Format.fromWatch] : [])
    }

    /// What was said in a note: the words of its lines, and nothing else. Not its front matter (title, date, start,
    /// end, source, model, tags, place, geo...), its heading or each line's "[00:12] Speaker 1:": every note has those,
    /// so "start", "speaker", "phone" or a number matched every note.
    static func spoken(_ note: ConversationNote) -> String {
        note.lines.map(\.text).joined(separator: "\n")
    }
}

/// What was said in each note, read once and kept while the app runs, so searching as you type doesn't read every
/// note on every key. A note is read again when its file changes (its size or date: a title or place added, words
/// edited on the Mac), and one that can't be read now (iCloud took it off this iPhone, it's moving or deleted) isn't
/// kept, so it's read once it's back. Reading never downloads from iCloud: an evicted note matches by its row alone.
actor TranscriptCache {
    static let shared = TranscriptCache()

    /// A note to search: its row's own fields (`NoteSearch.fields`) and its file.
    nonisolated struct Searched: Sendable {
        var id: String
        var url: URL
        var fields: [String]
    }

    nonisolated private struct Stamp: Equatable {
        var size: Int
        var modified: Date?
    }

    nonisolated private struct Entry {
        var stamp: Stamp
        var spoken: String
    }

    private var entries: [URL: Entry] = [:]

    /// The ids of the notes with every word of `query` somewhere in their fields or what was said. `readingNew`: read
    /// the notes not read yet (or changed since); without it only what's read already counts, which is quick enough
    /// for every key.
    func matching(_ query: String, in notes: [Searched], readingNew: Bool = true) -> Set<String> {
        var out: Set<String> = []
        for note in notes {
            if Task.isCancelled { return out }
            guard let spoken = spoken(note.url, reading: readingNew) else { continue }
            if NoteSearch.matches(query, in: note.fields + [spoken]) { out.insert(note.id) }
        }
        // A note no longer listed (deleted, or listed again from where it moved) isn't kept.
        if readingNew {
            let listed = Set(notes.map(\.url))
            entries = entries.filter { listed.contains($0.key) }
        }
        return out
    }

    /// The words of the note at `url`: from memory while the file is as it was, else read again (only if `reading`).
    private func spoken(_ url: URL, reading: Bool) -> String? {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path) else {
            entries[url] = nil
            return nil
        }
        let stamp = Stamp(
            size: (attributes[.size] as? NSNumber)?.intValue ?? -1, modified: attributes[.modificationDate] as? Date)
        if let entry = entries[url], entry.stamp == stamp { return entry.spoken }
        guard reading else { return nil }
        guard let note = try? NoteStore(root: url.deletingLastPathComponent()).read(url: url) else {
            entries[url] = nil
            return nil
        }
        let spoken = NoteSearch.spoken(note)
        entries[url] = Entry(stamp: stamp, spoken: spoken)
        return spoken
    }
}

/// Notes found by their words, with the query they were found for. A new query's search answers a moment later; until
/// then the last matches show only when the query just gained or lost letters or words, never for a different one.
nonisolated struct TextMatches: Equatable {
    var query = ""
    var ids: Set<String> = []

    func ids(for query: String) -> Set<String> {
        guard !query.isEmpty, !self.query.isEmpty else { return [] }
        if query == self.query { return ids }
        let related = query.localizedCaseInsensitiveContains(self.query)
            || self.query.localizedCaseInsensitiveContains(query)
        return related ? ids : []
    }
}
