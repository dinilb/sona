import SwiftUI
import WidgetKit

// The small pieces the Live Activity, the Control and the widgets share, so they all say things the same way.

enum WidgetFormat {
    /// A recording's length the way `Text(timerInterval:)` counts it: "2:14", and "1:02:07" from an hour on.
    static func duration(_ interval: TimeInterval) -> String {
        let total = max(0, Int(interval))
        let hours = total / 3600, minutes = total % 3600 / 60, seconds = total % 60
        return hours > 0
            ? String(format: "%d:%02d:%02d", hours, minutes, seconds)
            : String(format: "%d:%02d", minutes, seconds)
    }

    /// When the newest note was made: "9:41 AM" today, "Yesterday", otherwise "Mon 2 Nov". The widgets don't refresh
    /// by themselves, so this reads `now` from the timeline entry and never relies on "ago" wording that would go
    /// stale.
    static func when(_ date: Date, now: Date = .now) -> String {
        let calendar = Calendar.current
        if calendar.isDate(date, inSameDayAs: now) {
            return date.formatted(date: .omitted, time: .shortened)
        }
        if let yesterday = calendar.date(byAdding: .day, value: -1, to: now), calendar.isDate(date, inSameDayAs: yesterday) {
            return "Yesterday"
        }
        return date.formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated))
    }
}

/// A recording's length: counting by itself while it runs (the system keeps the timer, so the app only has to update
/// the Live Activity when something changes), fixed at `stoppedAt` once it's stopped or while the mic is paused.
struct ElapsedText: View {
    var startedAt: Date
    var stoppedAt: Date?

    var body: some View {
        if let stoppedAt {
            Text(WidgetFormat.duration(stoppedAt.timeIntervalSince(startedAt)))
        } else {
            Text(timerInterval: startedAt...Date.distantFuture, countsDown: false)
        }
    }
}

extension WidgetRenderingMode {
    /// The system's primary and secondary, in full colour (light and dark) and on a tinted Home Screen alike, where
    /// everything is drawn in its tint.
    var ink: AnyShapeStyle { AnyShapeStyle(HierarchicalShapeStyle.primary) }

    var grey: AnyShapeStyle { AnyShapeStyle(HierarchicalShapeStyle.secondary) }
}

/// Small grey text: status and times.
struct Meta: View {
    var text: String
    @Environment(\.widgetRenderingMode) private var mode

    init(_ text: String) { self.text = text }

    var body: some View {
        Text(text).font(.caption).monospacedDigit().foregroundStyle(mode.grey).lineLimit(1).minimumScaleFactor(0.75)
    }
}

/// The red dot, which only ever means "recording".
struct RecordingDot: View {
    var size: CGFloat = 8
    var color: Color = SonaTheme.accent

    var body: some View {
        Circle().fill(color).frame(width: size, height: size)
    }
}

/// The dot as a grey ring: a recording that isn't hearing anything (paused, or the app stopped answering). Grey,
/// not red: red is only ever a recording that hears.
struct RingDot: View {
    var size: CGFloat = 8
    var color: Color = .secondary

    var body: some View {
        Circle().strokeBorder(color, lineWidth: 1.5).frame(width: size, height: size)
    }
}
