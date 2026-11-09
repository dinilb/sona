import XCTest

@testable import NotesKit

/// The sidebar's days: the last 7 by name, then older days under their month, newest first.
final class DayGroupsTests: XCTestCase {
    let brisbane = TimeZone(identifier: "Australia/Brisbane")!

    func at(_ iso: String) -> Date { ISO8601DateFormatter().date(from: iso)! }

    func testLastSevenDaysByNameThenMonths() {
        // Friday 30 Oct 2026. Days repeat once per conversation, newest first like `NoteStore.names()`.
        let days = [
            "2026-10-30", "2026-10-30", "2026-10-29", "2026-10-29", "2026-10-29", "2026-10-28", "2026-10-26", "2026-10-24",
            "2026-10-23", "2026-10-21", "2026-10-01", "2026-09-28", "2026-09-12", "2025-12-18",
        ]
        let groups = DayGroups(days: days, today: "2026-10-30")
        XCTAssertEqual(groups.recent.map(\.title), ["today", "yesterday", "wednesday", "monday", "saturday"])
        XCTAssertEqual(groups.recent.map(\.count), [2, 3, 1, 1, 1])
        XCTAssertEqual(groups.recent.map(\.day), ["2026-10-30", "2026-10-29", "2026-10-28", "2026-10-26", "2026-10-24"])
        // A week ago is under its month: "friday" would read as today.
        XCTAssertEqual(groups.months.map(\.title), ["october", "september", "december 2025"])
        XCTAssertEqual(groups.months.map(\.id), ["2026-10", "2026-09", "2025-12"])
        XCTAssertEqual(groups.months.map(\.startsOpen), [true, false, false])
        XCTAssertEqual(groups.months[0].days.map(\.title), ["23rd of october", "21st of october", "1st of october"])
        XCTAssertEqual(groups.months[1].days.map(\.title), ["28th of september", "12th of september"])
        XCTAssertEqual(groups.months[2].days.map(\.title), ["18th of december 2025"])
    }

    func testOrderDoesntMatter() {
        let groups = DayGroups(days: ["2026-09-01", "notes", "2026-10-30", "2026-10-02", "2026-10-30"], today: "2026-10-30")
        XCTAssertEqual(groups.recent, [DayGroups.Day(day: "2026-10-30", title: "today", count: 2)])
        XCTAssertEqual(groups.months.map(\.id), ["2026-10", "2026-09"])
        XCTAssertTrue(DayGroups(days: [], today: "2026-10-30").recent.isEmpty)
    }

    /// A folder that isn't a real date still shows, under the nearest one that is (keeping its own folder name).
    func testOddFoldersStillShow() {
        let groups = DayGroups(days: ["2026-00-10", "2026-13-01", "2026-02-31", "2026-10-30"], today: "2026-10-30")
        XCTAssertEqual(groups.recent.map(\.day), ["2026-10-30"])
        XCTAssertEqual(groups.months.map(\.title), ["december", "february", "january"])
        XCTAssertEqual(groups.months.map(\.id), ["2026-12", "2026-02", "2026-01"])
        XCTAssertEqual(groups.months.flatMap(\.days).map(\.day), ["2026-13-01", "2026-02-31", "2026-00-10"])
        XCTAssertEqual(groups.months.flatMap(\.days).map(\.title), ["1st of december", "28th of february", "10th of january"])
        XCTAssertEqual(groups.allDays.count, 4)
        XCTAssertEqual(DayGroups.longTitle("2026-00-10", today: "2026-10-30"), "10th of january")
    }

    /// A folder dated after today (a wrong clock) never sits above today: it's under its month, which stays closed.
    func testFutureDaysGoUnderTheirMonth() {
        let groups = DayGroups(days: ["2030-01-05", "2026-10-31", "2026-10-30", "2026-10-12"], today: "2026-10-30")
        XCTAssertEqual(groups.recent.map(\.title), ["today"])
        XCTAssertEqual(groups.months.map(\.title), ["january 2030", "october"])
        XCTAssertEqual(groups.months[1].days.map(\.title), ["31st of october", "12th of october"])
        XCTAssertEqual(groups.months.map(\.startsOpen), [false, true])
        // Early in a month, a wrong-clock day in it doesn't open that month: last month's real days do.
        let early = DayGroups(days: ["2026-11-03", "2026-11-01", "2026-10-20"], today: "2026-11-02")
        XCTAssertEqual(early.months.map(\.title), ["november", "october"])
        XCTAssertEqual(early.months.map(\.startsOpen), [false, true])
    }

    /// When the open day goes away, the selection moves to the next older day showing, else the newest left.
    func testNearestDay() {
        let shown = ["2026-10-30", "2026-10-28", "2026-10-21"]
        XCTAssertEqual(DayGroups.nearest(to: "2026-10-29", in: shown), "2026-10-28")
        XCTAssertEqual(DayGroups.nearest(to: "2026-10-31", in: shown), "2026-10-30")
        XCTAssertEqual(DayGroups.nearest(to: "2026-10-01", in: shown), "2026-10-21")
        XCTAssertNil(DayGroups.nearest(to: "2026-10-01", in: []))
        let groups = DayGroups(days: ["2026-10-30", "2026-10-12", "2026-09-28"], today: "2026-10-30")
        XCTAssertEqual(groups.shownDays { $0.startsOpen }, ["2026-10-30", "2026-10-12"])
        XCTAssertEqual(groups.allDays, ["2026-10-30", "2026-10-12", "2026-09-28"])
    }

    /// A conversation is on the day it started (its folder), even when it runs past midnight or it's now just after.
    func testConversationStartedBeforeMidnight() {
        let folder = ["2026-10-29"]  // started 23:58, ended 00:20
        XCTAssertEqual(DayGroups(days: folder, now: at("2026-10-29T23:59:00+10:00"), zone: brisbane).recent.map(\.title), ["today"])
        XCTAssertEqual(DayGroups(days: folder, now: at("2026-10-30T00:10:00+10:00"), zone: brisbane).recent.map(\.title), ["yesterday"])
        XCTAssertEqual(DayGroups(days: folder, now: at("2026-11-04T00:01:00+10:00"), zone: brisbane).recent.map(\.title), ["thursday"])
        XCTAssertEqual(DayGroups(days: folder, now: at("2026-11-04T23:59:00+10:00"), zone: brisbane).recent.map(\.title), ["thursday"])
        XCTAssertEqual(DayGroups(days: folder, now: at("2026-11-05T00:01:00+10:00"), zone: brisbane).months.map(\.title), ["october"])
    }

    /// Early in a month the new month has no older days yet: last month is the newest header, and it's open.
    func testMonthChange() {
        let days = ["2026-11-01", "2026-10-30", "2026-10-27", "2026-10-26", "2026-10-05", "2026-09-30"]
        let groups = DayGroups(days: days, today: "2026-11-02")
        XCTAssertEqual(groups.recent.map(\.title), ["yesterday", "friday", "tuesday"])
        XCTAssertEqual(groups.months.map(\.title), ["october", "september"])
        XCTAssertEqual(groups.months.map(\.startsOpen), [true, false])
        XCTAssertEqual(groups.months[0].days.map(\.title), ["26th of october", "5th of october"])
        // Once November has older days, November is the open one.
        let later = DayGroups(days: days, today: "2026-11-20")
        XCTAssertEqual(later.recent, [])
        XCTAssertEqual(later.months.map(\.title), ["november", "october", "september"])
        XCTAssertEqual(later.months.map(\.startsOpen), [true, false, false])
    }

    /// Across new year: last week's days keep their names, and last year's months and dates get the year.
    func testNewYear() {
        let days = ["2027-01-01", "2026-12-31", "2026-12-27", "2026-12-20", "2026-11-03"]
        let groups = DayGroups(days: days, today: "2027-01-02")
        XCTAssertEqual(groups.recent.map(\.title), ["yesterday", "thursday", "sunday"])
        XCTAssertEqual(groups.months.map(\.title), ["december 2026", "november 2026"])
        XCTAssertEqual(groups.months.map(\.startsOpen), [true, false])
        XCTAssertEqual(groups.months[0].days.map(\.title), ["20th of december 2026"])
        XCTAssertEqual(DayGroups.title("2026-12-20", today: "2027-01-02"), "20th of december 2026")
        XCTAssertEqual(DayGroups.title("2026-12-20", today: "2026-12-30"), "20th of december")
        XCTAssertEqual(DayGroups.longTitle("2026-12-31", today: "2027-01-02"), "thursday 31 dec 2026")
        XCTAssertEqual(DayGroups.longTitle("2026-10-29", today: "2026-10-30"), "thursday 29 oct")
    }

    /// "Today" is the day where this Mac is; days are counted on the calendar, so a clock change moves nothing.
    func testTimeZones() {
        let instant = at("2026-10-29T14:30:00Z")
        let days = ["2026-10-30", "2026-10-29"]
        // 00:30 on Friday in Brisbane.
        XCTAssertEqual(DayGroups(days: days, now: instant, zone: brisbane).recent.map(\.title), ["today", "yesterday"])
        // Still Thursday in London and Los Angeles: a note written ahead of here (on a trip) is under its month.
        let london = DayGroups(days: days, now: instant, zone: TimeZone(identifier: "Europe/London")!)
        XCTAssertEqual(london.recent.map(\.title), ["today"])
        XCTAssertEqual(london.months.flatMap(\.days).map(\.title), ["30th of october"])
        let la = DayGroups(days: days, now: instant, zone: TimeZone(identifier: "America/Los_Angeles")!)
        XCTAssertEqual(la.recent.map(\.title), ["today"])
        // Sydney's clocks went forward on 4 Oct 2026: that day was 23 hours long, and it's still yesterday.
        let sydney = TimeZone(identifier: "Australia/Sydney")!
        let afterChange = DayGroups(days: ["2026-10-04", "2026-09-29", "2026-09-28"], now: at("2026-10-05T00:30:00+11:00"), zone: sydney)
        XCTAssertEqual(afterChange.recent.map(\.title), ["yesterday", "tuesday"])
        XCTAssertEqual(afterChange.months.map(\.title), ["september"])
    }

    /// The weekday arithmetic agrees with Foundation's calendar on every day for 30 years.
    func testWeekdaysMatchTheCalendar() {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        var date = cal.date(from: DateComponents(year: 2000, month: 1, day: 1))!
        var previous: Int?
        while cal.component(.year, from: date) < 2030 {
            let c = cal.dateComponents([.year, .month, .day, .weekday], from: date)
            let text = String(format: "%04d-%02d-%02d", c.year!, c.month!, c.day!)
            let day = DayGroups.CalendarDay(text)!
            XCTAssertEqual(day.weekday, c.weekday! - 1, text)
            if let previous { XCTAssertEqual(day.number, previous + 1, text) }
            previous = day.number
            date = cal.date(byAdding: .day, value: 1, to: date)!
        }
    }

    /// Months opened or closed by a click are kept in the settings file; an older file without them still loads.
    func testOpenMonthsLastPastARelaunch() throws {
        var settings = Settings()
        settings.openMonths = ["2026-10": false, "2026-09": true]
        let back = try JSONDecoder().decode(Settings.self, from: JSONEncoder().encode(settings))
        XCTAssertEqual(back.openMonths, ["2026-10": false, "2026-09": true])
        XCTAssertEqual(try JSONDecoder().decode(Settings.self, from: Data(#"{"alwaysOn": true}"#.utf8)).openMonths, [:])
    }

    func testDuration() {
        XCTAssertEqual(DayGroups.duration(0), "0s")
        XCTAssertEqual(DayGroups.duration(40), "40s")
        XCTAssertEqual(DayGroups.duration(17 * 60 + 5), "17m")
        XCTAssertEqual(DayGroups.duration(85 * 60), "1h 25m")
        XCTAssertEqual(DayGroups.duration(2 * 3600 + 14 * 60 + 59), "2h 14m")
    }

    func testOrdinals() {
        let expected = [1: "1st", 2: "2nd", 3: "3rd", 4: "4th", 10: "10th", 11: "11th", 12: "12th", 13: "13th", 14: "14th",
                        20: "20th", 21: "21st", 22: "22nd", 23: "23rd", 24: "24th", 30: "30th", 31: "31st"]
        for (n, text) in expected { XCTAssertEqual(DayGroups.ordinal(n), text) }
    }

    func testOlderDayLabels() {
        XCTAssertEqual(DayGroups.title("2026-10-23", today: "2026-10-30"), "23rd of october")
        XCTAssertEqual(DayGroups.title("2025-12-03", today: "2026-10-30"), "3rd of december 2025")
        XCTAssertEqual(DayGroups.title("2026-10-24", today: "2026-10-30"), "saturday")
        XCTAssertEqual(DayGroups.longTitle("2026-10-23", today: "2026-10-30"), "23rd of october")
        XCTAssertEqual(DayGroups.longTitle("2025-12-03", today: "2026-10-30"), "3rd of december 2025")
        XCTAssertEqual(DayGroups.longTitle("2026-10-24", today: "2026-10-30"), "saturday 24 oct")
    }
}
