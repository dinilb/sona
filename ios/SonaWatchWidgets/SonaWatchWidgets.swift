import SwiftUI
import WidgetKit

@main
struct SonaWatchWidgets: WidgetBundle {
    var body: some Widget {
        RecordComplication()
    }
}

/// The watch-face button: one tap opens Sona and starts a note (`sona://record`); while recording it shows a voice
/// wave and the running time, and a tap stops it (`sona://stop`), which the circular and corner say with a stop square
/// and the rectangular with "tap to stop". Both links carry this watch's key (`LinkKey`): the watch app ignores one
/// without it. The watch app writes the status into the App Group and reloads this when its own recorder starts or
/// stops (`AppModel.connect`); a recording it hasn't said is alive for a few minutes shows as stopped.
struct RecordComplication: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "com.dinilb.sona.record", provider: RecordProvider()) { entry in
            RecordComplicationView(entry: entry)
                .widgetURL(entry.isRecording ? DeepLink.stop.url : DeepLink.record.url)
                .containerBackground(for: .widget) { Color.clear }
        }
        .configurationDisplayName("Record")
        .description("Starts a voice note in Sona.")
        .supportedFamilies([.accessoryCircular, .accessoryCorner, .accessoryInline, .accessoryRectangular])
    }
}

/// Plain values, so WidgetKit can make and pass these from any thread.
nonisolated struct RecordEntry: TimelineEntry {
    var date: Date
    var recordingSince: Date?
    var waiting: Int

    var isRecording: Bool { recordingSince != nil }
}

nonisolated struct RecordProvider: TimelineProvider {
    func placeholder(in context: Context) -> RecordEntry {
        RecordEntry(date: Date(), recordingSince: nil, waiting: 0)
    }

    func getSnapshot(in context: Context, completion: @escaping @Sendable (RecordEntry) -> Void) {
        Task { @MainActor in completion(Self.current()) }
    }

    func getTimeline(in context: Context, completion: @escaping @Sendable (Timeline<RecordEntry>) -> Void) {
        // One entry until the app says otherwise: the recording's time counts itself (`Text(timerInterval:)`). While
        // recording, it's asked for again every 15 minutes, so an app that died mid-recording stops showing as
        // recording once its heartbeat is stale. Only one entry: a second "stopped" entry would switch a live
        // recording off whenever a reload came late.
        Task { @MainActor in
            let entry = Self.current()
            let policy: TimelineReloadPolicy =
                entry.isRecording ? .after(entry.date.addingTimeInterval(15 * 60)) : .never
            completion(Timeline(entries: [entry], policy: policy))
        }
    }

    @MainActor private static func current() -> RecordEntry {
        let status = SharedStatus.load()
        let now = Date()
        return RecordEntry(date: now, recordingSince: status.liveRecordingSince(now: now), waiting: status.waiting)
    }
}

struct RecordComplicationView: View {
    let entry: RecordEntry
    @Environment(\.widgetFamily) private var family

    var body: some View {
        switch family {
        case .accessoryCorner: corner
        case .accessoryInline: inline
        case .accessoryRectangular: rectangular
        default: circular
        }
    }

    // While recording, every family shows how long it's been going and a voice wave. A complication can't animate or
    // redraw every second, so the wave stands still (it says "listening"); the time counts by itself. A tap while
    // recording stops it at once, so the circular and the corner keep a stop square: a wave and a counting time alone
    // look like a status you'd tap to check on. Idle, it's the app's record button: a red dot in a ring. Red is only
    // ever recording; the red parts are accentable, so a tinted face draws them in its tint.

    private var circular: some View {
        ZStack {
            AccessoryWidgetBackground()
            if let since = entry.recordingSince {
                Circle()
                    .strokeBorder(SonaTheme.accent, lineWidth: 2.5)
                    .widgetAccentable()
                // Narrow at the top and bottom, wide in the middle, to fit the circle.
                VStack(spacing: 1) {
                    Image(systemName: "stop.fill")
                        .font(.caption2)
                        .imageScale(.small)
                        .foregroundStyle(SonaTheme.accent)
                        .widgetAccentable()
                    Self.timer(since)
                        .font(.caption2.weight(.semibold))
                        .multilineTextAlignment(.center)
                        .lineLimit(1)
                        .minimumScaleFactor(0.6)  // "1:02:07" from an hour on
                    WaveMark(height: 7, barWidth: 1.5, gap: 1)
                        .foregroundStyle(SonaTheme.accent)
                        .widgetAccentable()
                }
                .padding(.horizontal, 4)
            } else {
                RecordMark(size: 30)
            }
        }
        // One element with the label: on a plain stack it went to the children, and idle the only one (the record
        // mark) is hidden, so VoiceOver had nothing to say.
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(entry.isRecording ? "Stop recording" : "Record a note")
        .accessibilityAddTraits(.isButton)
    }

    // The corner has room for one symbol, so it's the stop square (what a tap does) and the time is the label; idle,
    // the record button's dot in a ring.
    private var corner: some View {
        Image(systemName: entry.isRecording ? "stop.fill" : "record.circle")
            .font(.title3)
            .foregroundStyle(SonaTheme.accent)
            .widgetAccentable()
            .widgetLabel {
                if let since = entry.recordingSince {
                    Self.timer(since)
                } else if entry.waiting > 0 {
                    Text("\(entry.waiting) waiting")
                } else {
                    Text("Sona")
                }
            }
            .accessibilityLabel(entry.isRecording ? "Stop recording" : "Record a note")
    }

    private var inline: some View {
        Group {
            if let since = entry.recordingSince {
                // One image and one line, in the face's own colour: the wave is what says "recording" here.
                Label {
                    Text("Sona \(Self.timer(since))")
                } icon: {
                    Image(systemName: "waveform")
                }
            } else {
                Text("Sona: record")
            }
        }
    }

    private var rectangular: some View {
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 1) {
                Text("Sona")
                    .font(.headline)
                    .widgetAccentable()
                if let since = entry.recordingSince {
                    HStack(spacing: 6) {
                        WaveMark(height: 18)
                            .foregroundStyle(SonaTheme.accent)
                            .widgetAccentable()
                        Self.timer(since)
                            .font(.title3.weight(.semibold))
                            .lineLimit(1)
                    }
                    Text("Tap to stop")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                } else {
                    Text("Tap to record")
                    if entry.waiting > 0 {
                        Text("\(entry.waiting) waiting")
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .font(.body)
            Spacer(minLength: 0)
            // While recording, the wave and the time take the room, and the hint says a tap stops it.
            if !entry.isRecording { RecordMark(size: 30) }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// The recording's length, counting by itself (the system keeps the timer, so it needs no reloads): "2:14",
    /// "1:02:07" from an hour on.
    private static func timer(_ since: Date) -> Text {
        Text(timerInterval: since...Date.distantFuture, countsDown: false)
            .monospacedDigit()
    }
}

/// The watch app's record button, small: a red dot in a ring of the face's own colour. The dot is accentable, so a
/// tinted face draws it in its tint.
struct RecordMark: View {
    var size: CGFloat

    var body: some View {
        ZStack {
            Circle().strokeBorder(.primary, lineWidth: max(1.5, size * 0.07))
            Circle()
                .fill(SonaTheme.accent)
                .frame(width: size * 0.62, height: size * 0.62)
                .widgetAccentable()
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}

/// A voice wave that stands still: a few capsule bars like the watch app's live waveform, for the rectangular and
/// circular complications.
struct WaveMark: View {
    var height: CGFloat
    var barWidth: CGFloat = 2.5
    var gap: CGFloat = 1.5

    /// Bar heights, 0...1: loud and quiet, like a word.
    static let shape: [CGFloat] = [0.3, 0.6, 1, 0.45, 0.8, 0.35, 0.65]

    var body: some View {
        HStack(alignment: .center, spacing: gap) {
            ForEach(Self.shape.indices, id: \.self) { index in
                Capsule()
                    .frame(width: barWidth, height: max(barWidth, height * Self.shape[index]))
            }
        }
        .frame(height: height)
        .accessibilityHidden(true)
    }
}
