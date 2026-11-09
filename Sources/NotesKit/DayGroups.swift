import Foundation

/// The window's sidebar of days: the last 7 by name (today, yesterday, wednesday, ...), then older days under their
/// month. Newest first, only days with conversations. A conversation belongs to the day its folder is named after
/// (the day it started, in the time zone it was written), so one that runs past midnight stays on its first day.
public struct DayGroups: Equatable, Sendable {
    public struct Day: Equatable, Sendable {
        /// The folder name, `2026-10-29`.
        public var day: String
        /// "today", "yesterday", "wednesday", or "23rd of october" under a month.
        public var title: String
        public var count: Int
    }

    public struct Month: Equatable, Sendable {
        /// `2026-10`.
        public var id: String
        /// "october", or "december 2025" when it isn't this year.
        public var title: String
        /// The newest month (not counting one after today's, from a wrong clock) starts open, older ones closed.
        public var startsOpen = false
        public var days: [Day]
    }

    public var recent: [Day] = []
    public var months: [Month] = []

    /// `days`: each conversation's day (`NoteName.day`), in any order. "Today" is the day `now` falls on in `zone`.
    public init(days: [String], now: Date = Date(), zone: TimeZone = .current) {
        self.init(days: days, today: NoteWriter.dayString(now, zone: zone))
    }

    /// `today`: `yyyy-MM-dd`. Plain arithmetic, no date formatters: it's redone whenever the sidebar is drawn.
    public init(days: [String], today: String) {
        var counts: [String: Int] = [:]
        for day in days { counts[day, default: 0] += 1 }
        let now = CalendarDay(today)
        var newest: String?
        let dated = counts.keys.compactMap { day in CalendarDay(day).map { (day, $0) } }
        for (day, date) in dated.sorted(by: { ($0.1.number, $0.0) > ($1.1.number, $1.0) }) {
            let count = counts[day] ?? 0
            // A day after today (a wrong clock) isn't "today": it goes under its month.
            if let now, (0..<7).contains(now.number - date.number) {
                recent.append(Day(day: day, title: Self.title(day, today: today), count: count))
                continue
            }
            let row = Day(day: day, title: date.ordinal(yearIfNot: now?.year), count: count)
            // The month that starts open is the newest with a day up to today, never one only a wrong clock made.
            if newest == nil, let now, date.number <= now.number { newest = date.monthID }
            if months.last?.id == date.monthID {
                months[months.count - 1].days.append(row)
            } else {
                let name = CalendarDay.months[date.month - 1]
                let title = date.year == now?.year ? name : "\(name) \(date.year)"
                months.append(Month(id: date.monthID, title: title, days: [row]))
            }
        }
        if let open = months.firstIndex(where: { $0.id == newest }) { months[open].startsOpen = true }
    }

    /// Every day, open months or not.
    public var allDays: [String] { recent.map(\.day) + months.flatMap { $0.days.map(\.day) } }

    /// The day rows showing, in order, with `open` saying which months are.
    public func shownDays(open: (Month) -> Bool) -> [String] {
        recent.map(\.day) + months.filter(open).flatMap { $0.days.map(\.day) }
    }

    /// Where a day that's gone (its notes deleted or moved) was: the first of `days` older than it, else the last.
    public static func nearest(to gone: String, in days: [String]) -> String? {
        days.first { isOlder($0, than: gone) } ?? days.last
    }

    /// In the sidebar's order (newest first), `day` comes after `other`.
    public static func isOlder(_ day: String, than other: String) -> Bool {
        (CalendarDay(day)?.number ?? .min, day) < (CalendarDay(other)?.number ?? .min, other)
    }

    /// "today", "yesterday", the weekday for the rest of the last 7 days ("wednesday"), else "23rd of october" (with
    /// the year when it isn't this one).
    public static func title(_ day: String, today: String) -> String {
        guard let date = CalendarDay(day) else { return day }
        guard let now = CalendarDay(today) else { return date.ordinal(yearIfNot: nil) }
        switch now.number - date.number {
        case 0: return "today"
        case 1: return "yesterday"
        case 2...6: return CalendarDay.weekdays[date.weekday]
        default: return date.ordinal(yearIfNot: now.year)
        }
    }

    /// A day's own page and its conversations' breadcrumb: "thursday 29 oct" for the last 7 days, older ones
    /// "23rd of october" (with the year when it isn't this one).
    public static func longTitle(_ day: String, today: String) -> String {
        guard let date = CalendarDay(day) else { return day }
        let now = CalendarDay(today)
        if let now, !(0..<7).contains(now.number - date.number) { return date.ordinal(yearIfNot: now.year) }
        let title = "\(CalendarDay.weekdays[date.weekday]) \(date.day) \(CalendarDay.months[date.month - 1].prefix(3))"
        return date.year == now?.year ? title : "\(title) \(date.year)"
    }

    /// 1 is "1st", 2 "2nd", 3 "3rd", 4 "4th", 11 to 13 "th", 21 "21st", 22 "22nd", 23 "23rd", 31 "31st".
    public static func ordinal(_ n: Int) -> String {
        let suffix = (11...13).contains(n % 100) ? "th" : ["th", "st", "nd", "rd", "th", "th", "th", "th", "th", "th"][n % 10]
        return "\(n)\(suffix)"
    }

    /// "40s", "17m", "1h 25m".
    public static func duration(_ seconds: Double) -> String {
        let s = max(0, Int(seconds.rounded()))
        if s < 60 { return "\(s)s" }
        let m = s / 60
        return m < 60 ? "\(m)m" : "\(m / 60)h \(m % 60)m"
    }

    /// A calendar day, counted without clocks or time zones, so a daylight-saving change never moves one.
    struct CalendarDay {
        static let weekdays = ["sunday", "monday", "tuesday", "wednesday", "thursday", "friday", "saturday"]
        static let months = [
            "january", "february", "march", "april", "may", "june", "july", "august", "september", "october", "november", "december",
        ]

        var year: Int
        var month: Int
        var day: Int

        /// `yyyy-MM-dd`. A folder that isn't a real date (`2026-00-10`, made by hand or another app) counts as the
        /// nearest one that is, so its notes still show.
        init?(_ text: String) {
            let parts = text.split(separator: "-")
            guard text.count == 10, parts.count == 3, let y = Int(parts[0]), let m = Int(parts[1]), let d = Int(parts[2])
            else { return nil }
            year = y
            month = min(max(m, 1), 12)
            let leap = y % 4 == 0 && (y % 100 != 0 || y % 400 == 0)
            day = min(max(d, 1), [31, leap ? 29 : 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31][month - 1])
        }

        /// `2026-10`.
        var monthID: String { String(format: "%04d-%02d", year, month) }

        /// Days since 1 Jan 1970 (Howard Hinnant's days-from-civil).
        var number: Int {
            let y = month <= 2 ? year - 1 : year
            let era = (y >= 0 ? y : y - 399) / 400
            let yoe = y - era * 400
            let doy = (153 * (month + (month > 2 ? -3 : 9)) + 2) / 5 + day - 1
            return era * 146_097 + yoe * 365 + yoe / 4 - yoe / 100 + doy - 719_468
        }

        /// 0 is Sunday (1 Jan 1970 was a Thursday).
        var weekday: Int { ((number + 4) % 7 + 7) % 7 }

        /// "23rd of october", with the year after it unless it's `year`.
        func ordinal(yearIfNot year: Int?) -> String {
            let text = "\(DayGroups.ordinal(day)) of \(Self.months[month - 1])"
            return self.year == year ? text : "\(text) \(self.year)"
        }
    }
}
