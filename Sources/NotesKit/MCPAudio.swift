import Foundation

/// The MCP tools that reach past the notes, into audio not yet in a note (the conversation going on now, or one waiting
/// for its note): `current_conversation`, `transcript`, `live` past 10 minutes, and `search`'s in-progress part. That
/// audio is transcribed when asked (`SpoolAccess`), newest first, for at most `audioSeconds` a call: what isn't done by
/// then is said, and carries on in the background, so asking again soon gets it.
extension MCPServer {
    /// The most a call waits for audio to be transcribed: under the 60 s many clients allow a tool call.
    static let audioSeconds = 40.0
    /// `search` waits less: its notes answer at once.
    static let searchAudioSeconds = 20.0

    /// A stretch of the reply: one conversation's heading and its lines, each with its time.
    struct Section {
        var start: Date
        var header: String
        var rows: [(at: Date, text: String)]
        /// Said after its lines: what isn't transcribed yet, or why it couldn't be.
        var notes: [String] = []
    }

    /// Recordings in the spool that aren't notes yet, oldest first. One whose note is already written (the spool lets
    /// it go a moment later) is left to the note.
    func pendingRecordings() -> [SpoolRecording] {
        spool.recordings().filter { recording in
            guard let note = recording.note else { return true }
            // Relative to Conversations; an older entry's absolute path keeps its last two parts (day/name), as the
            // processor reads it.
            let relative = note.split(separator: "/").suffix(2).joined(separator: "/")
            return !FileManager.default.fileExists(atPath: store.root.appendingPathComponent(relative).path)
        }
    }

    // MARK: tools

    func transcriptTool(_ args: [String: Any]) throws -> String {
        guard let from = try time(args["from"]) else {
            throw ToolError(message: "`from` is required: a time like 14:05 or 2026-11-09 14:05.")
        }
        let to = try time(args["to"], end: true) ?? now()
        guard from < to else { throw ToolError(message: "`from` must be before `to`.") }
        return transcript(from: from, to: to)
    }

    func currentConversation(_ args: [String: Any]) -> String {
        let pending = pendingRecordings()
        let running = AppStatus.read(now: now()) != nil
        // The one being recorded, else the newest waiting for its note.
        guard let recording = pending.last(where: { !$0.closed }) ?? pending.last else {
            var out = running
                ? "No conversation is going on right now: nothing is being recorded."
                : "Sona isn't running, so nothing is being recorded."
            if let last = store.latest(1).first {
                out += " The last conversation was \(last.id) (\(last.date) \(last.start.prefix(5))-\(last.end.prefix(5))): read_conversation has it."
            }
            return out
        }
        let deadline = Date().addingTimeInterval(Self.audioSeconds)
        let section = audioSection(recording, from: 0, to: recording.duration, deadline: deadline, running: running)
        var out: [String] = []
        let others = pending.filter { $0 != recording }
        if !others.isEmpty {
            let list = others.map { "\(clock($0.startedAt))-\(clock($0.endedAt))" }.joined(separator: ", ")
            out.append("Also not a note yet: \(list). transcript reads any of them.")
        }
        // The newest lines that fit: they're what "now" is about. The rest is one transcript call away.
        var budget = Self.replyBudget - section.header.count - section.notes.reduce(0) { $0 + $1.count + 1 }
        var kept: [String] = []
        for row in section.rows.reversed() {
            budget -= row.text.count + 1
            if budget < 0, !kept.isEmpty { break }
            kept.insert(row.text, at: 0)
        }
        out.append(section.header)
        if kept.count < section.rows.count {
            let cut = section.rows[section.rows.count - kept.count].at
            out.append("(The start, \(clock(recording.startedAt)) to \(clock(cut)), doesn't fit here: transcript from=\"\(stamp(recording.startedAt))\" to=\"\(stamp(cut))\" has it.)")
        }
        out += kept
        if section.rows.isEmpty, section.notes.isEmpty { out.append("(No words yet.)") }
        out += section.notes
        return out.joined(separator: "\n")
    }

    /// `live` with `minutes` or `since`: up to 10 minutes it's the live transcript; further back, `transcript` (the
    /// live transcript only keeps 10 minutes).
    func liveTool(_ args: [String: Any]) throws -> String {
        var window: Double?
        if let since = try time(args["since"]) {
            window = now().timeIntervalSince(since)
            guard window! > 0 else { throw ToolError(message: "`since` must be in the past.") }
        } else if let minutes = double(args["minutes"]), minutes.isFinite {
            guard minutes > 0 else { throw ToolError(message: "`minutes` must be more than 0.") }
            window = minutes * 60
        }
        guard let window else { return live(args) }
        if window <= 600 {
            var rest = args
            rest["seconds"] = window
            rest["minutes"] = nil
            rest["since"] = nil
            rest["words"] = nil
            return live(rest)
        }
        let window366 = min(window, 366 * 86_400)
        return transcript(
            from: now().addingTimeInterval(-window366), to: now(),
            intro: "The live transcript only keeps 10 minutes, so this is from the notes and the audio not yet in a note.")
    }

    // MARK: transcript

    /// What was said `from..<to`, in time order: the notes' lines, and audio not yet in a note transcribed now. A
    /// heading per conversation; cut at `replyBudget` characters, saying where to go on from.
    func transcript(from: Date, to: Date, intro: String? = nil) -> String {
        var sections: [Section] = []
        // A note's folder is the day it started: one from the day before can run into `from`.
        for note in store.conversations(from: NoteWriter.dayString(from.addingTimeInterval(-86_400)), to: NoteWriter.dayString(to)) {
            guard let start = note.startedAt, start < to else { continue }
            let rows = note.lines.compactMap { line -> (at: Date, text: String)? in
                let at = start.addingTimeInterval(line.offset)
                return at >= from && at < to ? (at, render(line, in: note)) : nil
            }
            if !rows.isEmpty { sections.append(Section(start: start, header: header(note), rows: rows)) }
        }
        let running = AppStatus.read(now: now()) != nil
        let deadline = Date().addingTimeInterval(Self.audioSeconds)
        for recording in pendingRecordings() where recording.startedAt < to && recording.endedAt > from {
            sections.append(audioSection(
                recording, from: max(0, from.timeIntervalSince(recording.startedAt)),
                to: min(recording.duration, to.timeIntervalSince(recording.startedAt)), deadline: deadline, running: running))
        }
        sections.sort { $0.start < $1.start }

        var out = [intro, "What was said \(stamp(from)) to \(stamp(to)):"].compactMap { $0 }
        guard !sections.isEmpty else {
            out.append("Nothing was heard then (no notes, and no audio waiting to become one).")
            return out.joined(separator: "\n")
        }
        var budget = Self.replyBudget
        var shown = 0
        for section in sections {
            out.append("")
            out.append(section.header)
            budget -= section.header.count + 1
            for row in section.rows {
                budget -= row.text.count + 1
                // At least one line a reply, so going on from the next always gets somewhere.
                if budget < 0, shown > 0 {
                    out.append("... cut off here. Call again with from=\"\(stamp(row.at))\" for the rest.")
                    return out.joined(separator: "\n")
                }
                out.append(row.text)
                shown += 1
            }
            out += section.notes
        }
        return out.joined(separator: "\n")
    }

    /// Seconds `from..<to` of a recording not yet a note, transcribed now (or what's done by `deadline`), as a section.
    func audioSection(_ recording: SpoolRecording, from: Double, to: Double, deadline: Date, running: Bool) -> Section {
        let state = switch (recording.closed, running) {
            case (false, true): "still recording"
            case (true, true): "ended, its note is being written"
            default: "left from when Sona stopped; it becomes a note when Sona starts"
        }
        var section = Section(start: recording.startedAt.addingTimeInterval(from), header: "", rows: [])
        var speakers: [String] = []
        do {
            let slice = try spool.transcribe(recording.id, from, to, max(1, deadline.timeIntervalSinceNow))
            if let error = slice.error {
                section.notes.append("(Couldn't transcribe it: \(error))")
            } else {
                let words = WordFixer(Settings.load().words).apply(slice.words)
                for line in Lines.from(words) {
                    let at = recording.startedAt.addingTimeInterval(line.start)
                    section.rows.append((at, "[\(Lines.clock(line.start))] (\(clock(at))) \(line.speaker): \(line.text)"))
                }
                for w in words where w.shown && !speakers.contains(w.speaker) { speakers.append(w.speaker) }
                if !slice.complete {
                    let a = recording.startedAt.addingTimeInterval(slice.from), b = recording.startedAt.addingTimeInterval(slice.doneFrom)
                    section.notes.append(
                        "(Not transcribed yet: \(clock(a)) to \(clock(b)). That carries on in the background: call again in a minute for it.)")
                }
            }
        } catch {
            section.notes.append("(Couldn't transcribe it: \((error as? SpoolFailure)?.description ?? "the transcriber failed."))")
        }
        let length = Lines.durationText(recording.duration)
        let who = speakers.isEmpty ? "" : " | \(speakers.joined(separator: ", "))"
        section.header = "## Not a note yet: started \(NoteWriter.dayString(recording.startedAt)) \(clock(recording.startedAt)), \(length) so far, \(state)"
            + " | transcribed just now from its audio, so its speaker numbers are this reply's own\(who)"
        return section
    }

    // MARK: search

    /// Lines of audio not yet in a note with every word of `query` (like the notes' search: case and accent
    /// insensitive, inside other words too), newest first. `from`, `to`: dates, YYYY-MM-DD.
    func pendingSearch(_ query: String, from: String?, to: String?, speaker: String?) -> [String] {
        let terms = NoteStore.searchTerms(query)
        guard !terms.isEmpty else { return [] }
        let running = AppStatus.read(now: now()) != nil
        let deadline = Date().addingTimeInterval(Self.searchAudioSeconds)
        let speakerKey = speaker.map(SearchIndex.speakerKey)
        var hits: [String] = []
        var notes: [String] = []
        for recording in pendingRecordings().reversed() {
            let day = NoteWriter.dayString(recording.startedAt)
            if let from, NoteWriter.dayString(recording.endedAt) < from { continue }
            if let to, day > to { continue }
            let section = audioSection(recording, from: 0, to: recording.duration, deadline: deadline, running: running)
            let label = "not a note yet (started \(clock(recording.startedAt)))"
            for row in section.rows.reversed() {
                // "[mm:ss] (HH:mm:ss) Speaker: text": match on "Speaker: text", like a note's line.
                guard let close = row.text.range(of: ") ") else { continue }
                let said = String(row.text[close.upperBound...])
                if let speakerKey, let colon = said.range(of: ": "), SearchIndex.speakerKey(String(said[..<colon.lowerBound])) != speakerKey { continue }
                guard terms.allSatisfy({ said.range(of: $0, options: [.caseInsensitive, .diacriticInsensitive]) != nil }) else { continue }
                hits.append("\(label) · \(day) \(row.text)")
            }
            notes += section.notes
        }
        guard !hits.isEmpty || !notes.isEmpty else { return [] }
        var out = hits.isEmpty
            ? ["No lines match \"\(query)\" in audio not yet in a note."]
            : ["\(hits.count) matching line(s) in audio not yet in a note (the conversation going on now, or one waiting for its note):"]
        out += Self.fitting(hits)
        out += notes
        return out
    }

    // MARK: times

    /// A time an AI passed: 14:05 or 14:05:30 (today, or yesterday if that's still to come), 2026-11-09 14:05[:30],
    /// ISO 8601 with or without a UTC offset, `now`, or a date alone (its start; `end`: the end of it).
    func time(_ value: Any?, end: Bool = false) throws -> Date? {
        guard let raw = (value as? String)?.trimmingCharacters(in: .whitespaces), !raw.isEmpty else { return nil }
        let bad = ToolError(message: "Times look like 14:05, 2026-11-09 14:05 or 2026-11-09T14:05:00+10:00 (got \"\(raw)\").")
        if raw.lowercased() == "now" { return now() }
        if let iso = Self.parseISO(raw) { return iso }
        let s = raw.replacingOccurrences(of: "T", with: " ")
        if s.range(of: #"^\d{4}-\d{2}-\d{2}$"#, options: .regularExpression) != nil {
            guard let day = ConversationNote.parse(s, "00:00") else { throw bad }
            return end ? Calendar.current.date(byAdding: .day, value: 1, to: day) : day
        }
        guard let match = s.range(of: #"^(\d{4}-\d{2}-\d{2} )?\d{1,2}:\d{2}(:\d{2})?$"#, options: .regularExpression), match == s.startIndex..<s.endIndex
        else { throw bad }
        let parts = s.split(separator: " ")
        let clockPart = parts.last.map(String.init) ?? ""
        let numbers = clockPart.split(separator: ":").compactMap { Int($0) }
        guard numbers.count >= 2, numbers[0] < 24, numbers[1] < 60, numbers.count < 3 || numbers[2] < 60 else { throw bad }
        let normal = String(format: "%02d:%02d:%02d", numbers[0], numbers[1], numbers.count > 2 ? numbers[2] : 0)
        if parts.count == 2 {
            guard let date = ConversationNote.parse(String(parts[0]), normal) else { throw bad }
            return date
        }
        guard var date = ConversationNote.parse(NoteWriter.dayString(now()), normal) else { throw bad }
        if date > now().addingTimeInterval(60) { date = Calendar.current.date(byAdding: .day, value: -1, to: date) ?? date }
        return date
    }

    func clock(_ date: Date) -> String { NoteWriter.timeString(date, "HH:mm:ss") }

    /// A time as `time` reads it back: "2026-11-09 14:05:30".
    func stamp(_ date: Date) -> String { NoteWriter.timeString(date, "yyyy-MM-dd HH:mm:ss") }
}
