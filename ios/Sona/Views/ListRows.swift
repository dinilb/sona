import Foundation
import NotesKit

// What the lists show, worked out without SwiftUI or files so it can be tested: the rows, the days they fall in, the
// places, and how times and days read ("7:05am – 11am", "Today, 6 Nov").

/// The screens Home pushes: a note, and Settings with its privacy page. Home is the one list (a place's notes are a
/// filter on Home, `AppModel.placeFilter`).
nonisolated enum Route: Hashable, Sendable {
    /// One note, by its id.
    case note(String)
    case settings
    case privacy
}

/// A row in a list: a note, or a recording that isn't a note yet (waiting, being transcribed, or failed this launch).
nonisolated struct NoteRow: Identifiable, Hashable, Sendable {
    enum State: Hashable, Sendable { case note, waiting, transcribing, failed }

    static let spoolPrefix = "spool:"

    /// The note's id (`2026-11-06/07-05 Title`), or `spool:<spool id>` for a recording.
    var id: String
    var state: State
    var title: String
    var startedAt: Date
    /// When it stopped, if that's known.
    var endedAt: Date?
    /// How long, as notes say it: "18m 28s".
    var length: String
    /// Where it started, and where it stopped when that's well away (a short street name).
    var place: String?
    var placeEnd: String?
    var isWatch = false
    var keepAudio = false
    var hasAudio = false
    /// In the notes folder, not still waiting on this iPhone to move there.
    var isSynced = true
    /// Kept in the "On this iPhone" folder after notes went somewhere else: it never syncs.
    var keptOnIPhone = false
    /// For a recording, what's happening to it ("waits for the speech model").
    var status: String?

    /// The spool id of a recording row; nil for a note.
    var spoolID: String? { id.hasPrefix(Self.spoolPrefix) ? String(id.dropFirst(Self.spoolPrefix.count)) : nil }

    /// Its places, start first, each once.
    var places: [String] {
        var out: [String] = []
        for name in [place, placeEnd].compactMap({ $0 }) where !name.isEmpty && !out.contains(name) { out.append(name) }
        return out
    }

    /// It started or stopped at `name`.
    func isAt(_ name: String) -> Bool { place == name || placeEnd == name }

    /// The grey line under the title: "7:05am – 11am · 18m 28s · from watch · on this iPhone, not synced yet", or for a
    /// recording "7:05am · 4m 12s · waits for the speech model". `notesChoice`: where notes go now.
    func meta(notesChoice: NotesChoice?) -> String {
        var parts = [Format.timeRange(startedAt, state == .note ? endedAt : nil), length]
        // A recording that isn't a note yet already says so in its title ("Watch recording").
        if isWatch, state == .note { parts.append(Format.fromWatch) }
        // Not when notes stay on this iPhone anyway: there it only waits a few seconds for its title and place.
        if state == .note, keptOnIPhone {
            parts.append("on this iPhone")
        } else if state == .note, !isSynced, notesChoice != .iphone {
            parts.append("on this iPhone, not synced yet")
        }
        if let status { parts.append(status) }
        return parts.filter { !$0.isEmpty }.joined(separator: " · ")
    }

    /// Home's grey line, as separate pieces the row spaces out (no middle dots): when ("4:25 pm" today, "Yesterday",
    /// "Thursday", "2 Nov"), then where it started, then whether it's still on this iPhone. For a recording that isn't
    /// a note yet, what's happening to it instead of the place ("Transcribing").
    func listParts(
        notesChoice: NotesChoice?, now: Date = Date(), calendar: Calendar = .autoupdatingCurrent,
        locale: Locale = .autoupdatingCurrent
    ) -> [String] {
        var parts = [Format.listDay(startedAt, now: now, calendar: calendar, locale: locale)]
        switch state {
        case .note: break
        case .transcribing: return parts + ["Transcribing"]
        case .failed: return parts + ["Couldn't transcribe. Tap to try again."]
        case .waiting: return parts + (status.map { [Format.sentence($0)] } ?? [])
        }
        if let place = places.first { parts.append(place) }
        if keptOnIPhone {
            parts.append("On this iPhone")
        } else if !isSynced, notesChoice != .iphone {
            parts.append("Not synced yet")
        }
        return parts
    }

    /// The length on the right, as Voice Memos writes it: "0:11", "4:25", "1:02:09"; nil when it isn't known.
    var lengthClock: String? { Format.seconds(fromLength: length).map { Format.clock($0) } }

    /// The length as VoiceOver says it ("4 minutes, 25 seconds"); nil when it isn't known.
    var lengthSpoken: String? { Format.seconds(fromLength: length).map { Format.spokenLength($0) } }

    /// A recording that isn't a note yet.
    static func recording(
        id: String, startedAt: Date, seconds: Double, length: String, isWatch: Bool, state: State, modelReady: Bool
    ) -> NoteRow {
        NoteRow(
            id: spoolPrefix + id, state: state, title: isWatch ? "Watch recording" : "Recording", startedAt: startedAt,
            endedAt: startedAt.addingTimeInterval(seconds), length: length, isWatch: isWatch,
            status: status(state, modelReady: modelReady))
    }

    /// What a recording row says about where it's at.
    static func status(_ state: State, modelReady: Bool) -> String? {
        switch state {
        case .note: nil
        case .transcribing: "transcribing"
        case .failed: "couldn't transcribe · tap to try again"
        case .waiting: modelReady ? "waiting to transcribe" : "waits for the speech model"
        }
    }
}

/// One day's rows.
nonisolated struct DayGroup: Identifiable, Hashable, Sendable {
    /// "2026-11-06", the same day as the notes' folders.
    var id: String
    /// The start of that day.
    var date: Date
    /// In the day's order: recordings that aren't notes yet first, then the notes, oldest first.
    var rows: [NoteRow]

    var count: Int { rows.count }
    /// Recordings that aren't notes yet.
    var waiting: Int { rows.filter { $0.state != .note }.count }
}

/// Home's order: one flat list, like Voice Memos.
nonisolated enum HomeOrder {
    /// Recordings that aren't notes yet first (they're what's happening now), then the notes; newest first in each.
    static func rows(_ rows: [NoteRow]) -> [NoteRow] {
        rows.sorted { a, b in
            let aNote = a.state == .note, bNote = b.state == .note
            if aNote != bNote { return !aNote }
            if a.startedAt != b.startedAt { return a.startedAt > b.startedAt }
            return a.id > b.id
        }
    }
}

nonisolated enum DayList {
    /// The rows by day, newest day first; each day reads like the day (see `DayGroup.rows`).
    static func days(_ rows: [NoteRow], calendar: Calendar = .current) -> [DayGroup] {
        var byDay: [String: [NoteRow]] = [:]
        for row in rows { byDay[dayID(row.startedAt, calendar: calendar), default: []].append(row) }
        return byDay.map { id, rows in
            DayGroup(id: id, date: calendar.startOfDay(for: rows[0].startedAt), rows: inDayOrder(rows))
        }
        .sorted { $0.id > $1.id }
    }

    /// Recordings that aren't notes yet first (they're what's happening now), then the notes oldest first.
    static func inDayOrder(_ rows: [NoteRow]) -> [NoteRow] {
        rows.sorted { a, b in
            let aNote = a.state == .note, bNote = b.state == .note
            if aNote != bNote { return !aNote }
            if a.startedAt != b.startedAt { return a.startedAt < b.startedAt }
            return a.id < b.id
        }
    }

    /// Every row made at `place` (where it started or stopped), by day, newest day first.
    static func days(at place: String, in rows: [NoteRow], calendar: Calendar = .current) -> [DayGroup] {
        days(rows.filter { $0.isAt(place) }, calendar: calendar)
    }

    /// "2026-11-06" in `calendar`'s time zone: sorts as text, and matches the notes' day folders.
    static func dayID(_ date: Date, calendar: Calendar = .current) -> String {
        let c = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
    }

    /// The start of the day a note id's folder names (`2026-11-06/...`), for a note whose header has no time.
    static func date(ofNoteID id: String, calendar: Calendar = .current) -> Date? {
        let parts = id.prefix(10).split(separator: "-").compactMap { Int($0) }
        guard parts.count == 3 else { return nil }
        return calendar.date(from: DateComponents(year: parts[0], month: parts[1], day: parts[2]))
    }
}

nonisolated enum Format {
    /// "7:05am", "11am" (or "07:05" where the clock is 24-hour).
    static func time(_ date: Date, locale: Locale = .autoupdatingCurrent, timeZone: TimeZone = .autoupdatingCurrent) -> String {
        let formatter = DateFormatter()
        formatter.locale = locale
        formatter.timeZone = timeZone
        guard uses12HourClock(locale) else {
            formatter.dateFormat = "HH:mm"
            return formatter.string(from: date)
        }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        formatter.dateFormat = calendar.component(.minute, from: date) == 0 ? "h a" : "h:mm a"
        // "7:05 AM", "7:05 am", "7:05\u{202F}AM" all become "7:05am".
        return formatter.string(from: date).lowercased().filter { !$0.isWhitespace && $0 != "." }
    }

    /// "7:05am – 11am"; just the start when it stopped within the same minute or isn't known.
    static func timeRange(
        _ start: Date, _ end: Date?, locale: Locale = .autoupdatingCurrent, timeZone: TimeZone = .autoupdatingCurrent
    ) -> String {
        let from = time(start, locale: locale, timeZone: timeZone)
        guard let end, end > start else { return from }
        let to = time(end, locale: locale, timeZone: timeZone)
        return to == from ? from : "\(from) – \(to)"
    }

    /// "Today, 6 Nov", "Yesterday, 5 Nov", "Wed 4 Nov", and "Tue 4 Nov 2025" in another year (the day and month in
    /// the locale's order).
    static func dayLabel(
        _ date: Date, now: Date = Date(), calendar: Calendar = .autoupdatingCurrent, locale: Locale = .autoupdatingCurrent
    ) -> String {
        let style = Date.FormatStyle(date: nil, time: nil, locale: locale, calendar: calendar, timeZone: calendar.timeZone)
        let dayMonth = date.formatted(style.day().month(.abbreviated))
        if calendar.isDate(date, inSameDayAs: now) { return "Today, \(dayMonth)" }
        if let yesterday = calendar.date(byAdding: .day, value: -1, to: now), calendar.isDate(date, inSameDayAs: yesterday) {
            return "Yesterday, \(dayMonth)"
        }
        let weekday = date.formatted(style.weekday(.abbreviated))
        if calendar.isDate(date, equalTo: now, toGranularity: .year) { return "\(weekday) \(dayMonth)" }
        return "\(weekday) \(date.formatted(style.day().month(.abbreviated).year()))"
    }

    /// Seconds in a length as notes write it ("1h 12m", "18m 28s", "40s"); nil if it isn't one.
    static func seconds(fromLength text: String) -> Double? {
        var total = 0.0
        var any = false
        for part in text.split(separator: " ") {
            guard let unit = part.last, let n = Double(part.dropLast()) else { return nil }
            switch unit {
            case "h": total += n * 3600
            case "m": total += n * 60
            case "s": total += n
            default: return nil
            }
            any = true
        }
        return any ? total : nil
    }

    /// Where it was: "4 Main St", or "4 Main St → 10 King St" when it stopped somewhere else.
    static func places(_ start: String?, _ end: String?) -> String? {
        switch (start, end) {
        case let (start?, end?) where start != end: "\(start) → \(end)"
        case let (start?, _): start
        case let (nil, end?): end
        case (nil, nil): nil
        }
    }

    /// Notes say where they were recorded (`source`); only the watch's is worth saying on this iPhone.
    static let fromWatch = "from watch"

    /// What a note's screen says about where it came from: "from watch", nothing for this iPhone's own, and any other
    /// source as it is (a file in a picked folder, say).
    static func origin(_ source: String?) -> String? {
        guard let source, !source.isEmpty, source != NoteSource.iPhone else { return nil }
        return AppModel.isWatch(source) ? fromWatch : source
    }

    /// Home's day: the time today ("4:25 pm", in the locale's own style), "Yesterday", the weekday within the week
    /// ("Thursday"), else the day and month ("2 Nov"), with the year when it isn't this one.
    static func listDay(
        _ date: Date, now: Date = Date(), calendar: Calendar = .autoupdatingCurrent, locale: Locale = .autoupdatingCurrent
    ) -> String {
        let style = Date.FormatStyle(date: nil, time: nil, locale: locale, calendar: calendar, timeZone: calendar.timeZone)
        if calendar.isDate(date, inSameDayAs: now) { return date.formatted(style.hour().minute()) }
        if let yesterday = calendar.date(byAdding: .day, value: -1, to: now), calendar.isDate(date, inSameDayAs: yesterday) {
            return "Yesterday"
        }
        if let weekAgo = calendar.date(byAdding: .day, value: -6, to: calendar.startOfDay(for: now)), date >= weekAgo, date < now {
            return date.formatted(style.weekday(.wide))
        }
        if calendar.isDate(date, equalTo: now, toGranularity: .year) { return date.formatted(style.day().month(.abbreviated)) }
        return date.formatted(style.day().month(.abbreviated).year())
    }

    /// When a note was made, under its title: "Today, 3:35 pm", "Yesterday, 9:10 am", "Thursday 6 Nov, 7:05 am", with
    /// the year when it isn't this one.
    static func noteWhen(
        _ start: Date, now: Date = Date(), calendar: Calendar = .autoupdatingCurrent, locale: Locale = .autoupdatingCurrent
    ) -> String {
        let style = Date.FormatStyle(date: nil, time: nil, locale: locale, calendar: calendar, timeZone: calendar.timeZone)
        let day: String
        if calendar.isDate(start, inSameDayAs: now) {
            day = "Today"
        } else if let yesterday = calendar.date(byAdding: .day, value: -1, to: now), calendar.isDate(start, inSameDayAs: yesterday) {
            day = "Yesterday"
        } else if calendar.isDate(start, equalTo: now, toGranularity: .year) {
            day = start.formatted(style.weekday(.wide).day().month(.abbreviated))
        } else {
            day = start.formatted(style.day().month(.abbreviated).year())
        }
        return "\(day), \(start.formatted(style.hour().minute()))"
    }

    /// A length as VoiceOver says it: "4 minutes, 25 seconds", "1 hour, 2 minutes, 9 seconds" (a bare "4:25" reads like
    /// a time of day).
    static func spokenLength(_ seconds: Double, locale: Locale = .autoupdatingCurrent) -> String {
        Duration.seconds(max(0, Int(seconds.rounded(.down))))
            .formatted(.units(allowed: [.hours, .minutes, .seconds], width: .wide).locale(locale))
    }

    /// "0:11", "4:25", "1:02:09": minutes without a leading zero, hours only past an hour.
    static func clock(_ seconds: Double) -> String {
        let s = max(0, Int(seconds.rounded(.down)))
        if s >= 3600 { return String(format: "%d:%02d:%02d", s / 3600, (s % 3600) / 60, s % 60) }
        return String(format: "%d:%02d", s / 60, s % 60)
    }

    /// The first letter capitalised, for the lower-case phrases the older screens used ("from watch" → "From watch").
    static func sentence(_ text: String) -> String {
        guard let first = text.first else { return text }
        return first.uppercased() + text.dropFirst()
    }

    /// The locale's clock has am and pm.
    static func uses12HourClock(_ locale: Locale) -> Bool {
        (DateFormatter.dateFormat(fromTemplate: "j", options: 0, locale: locale) ?? "").contains("a")
    }
}
