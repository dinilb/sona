import Foundation

// The entry point for scripts/widget-snapshots.sh: checks the widgets' text helpers, then draws every Live Activity and
// widget state to a PNG and prints where each one went. The first argument is the folder (default /tmp).

// The widgets are an app extension, so unit tests can't reach them; WidgetFormat is plain functions, so check them here.
var failures = 0
func check(_ ok: Bool, _ what: String) {
    if !ok {
        failures += 1
        print("FAILED: \(what)")
    }
}
let hour: TimeInterval = 3600
let now = Date.now
check(WidgetFormat.duration(0) == "0:00", "a zero length reads 0:00")
check(WidgetFormat.duration(-5) == "0:00", "a negative length reads 0:00")
check(WidgetFormat.duration(9) == "0:09", "nine seconds read 0:09")
check(WidgetFormat.duration(134) == "2:14", "134 seconds read 2:14")
check(WidgetFormat.duration(59 * 60 + 59) == "59:59", "an hour less a second reads 59:59")
check(WidgetFormat.duration(hour + 125) == "1:02:05", "an hour and 125 seconds read 1:02:05")
let yesterday = Calendar.current.date(byAdding: .day, value: -1, to: now)!
check(WidgetFormat.when(yesterday, now: now) == "Yesterday", "yesterday reads Yesterday (sentence case)")
let lastWeek = Calendar.current.date(byAdding: .day, value: -6, to: now)!
check(WidgetFormat.when(lastWeek, now: now).contains(where: \.isNumber), "an older note reads as a day and month")
check(WidgetFormat.when(now, now: now).contains(":"), "a note from today reads as a time")
check(WidgetFormat.when(now, now: now) == now.formatted(date: .omitted, time: .shortened), "times read as the system writes them")
if failures > 0 { exit(1) }
print("text helpers ok")

let folder = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "/tmp"
for url in WidgetSnapshots.renderAll(into: URL(fileURLWithPath: folder)) {
    print(url.path)
}
