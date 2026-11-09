import SwiftUI
import WidgetKit

/// The Lock Screen widgets and the Home Screen widget: a way into recording (a tap opens the app straight into it)
/// and a glance at the newest note and what's waiting. They read what the app wrote into the App Group
/// (`SharedStatus`); the app reloads their timelines when that changes, so they never refresh on their own.
struct StatusWidget: Widget {
    static let kind = "com.dinilb.sona.status"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: Self.kind, provider: StatusProvider()) { entry in
            StatusWidgetView(entry: entry)
        }
        .configurationDisplayName("Sona")
        .description("Tap to record a voice note. Shows your newest note and what's waiting.")
        .supportedFamilies([.systemSmall, .accessoryCircular, .accessoryRectangular, .accessoryInline])
    }
}

struct StatusEntry: TimelineEntry {
    var date: Date
    var status: SharedStatus
    /// It says it's recording, but the app hasn't said it's alive in time (`SharedStatus.staleAt`): it may have been
    /// killed, so this entry says "not recording · open sona" with no running timer.
    var stale = false
}

struct StatusProvider: TimelineProvider {
    func placeholder(in context: Context) -> StatusEntry {
        StatusEntry(date: .now, status: .gallery)
    }

    func getSnapshot(in context: Context, completion: @escaping @Sendable (StatusEntry) -> Void) {
        let status = context.isPreview ? SharedStatus.gallery : SharedStatus.load()
        completion(StatusEntry(date: .now, status: status, stale: status.isStale(at: .now)))
    }

    func getTimeline(in context: Context, completion: @escaping @Sendable (Timeline<StatusEntry>) -> Void) {
        completion(Timeline(entries: Self.entries(for: SharedStatus.load(), now: .now), policy: .never))
    }

    /// One entry for each moment the look changes by itself (`SharedStatus.timelineDates`). The policy is still
    /// `.never`: the app reloads when the status changes.
    static func entries(for status: SharedStatus, now: Date) -> [StatusEntry] {
        status.timelineDates(now: now).map { StatusEntry(date: $0, status: status, stale: status.isStale(at: $0)) }
    }
}

extension SharedStatus {
    /// What the widget gallery and the placeholder show.
    static var gallery: SharedStatus {
        SharedStatus(waiting: 1, latestTitle: "Ideas for the launch", latestAt: Date.now.addingTimeInterval(-20 * 60))
    }

    /// Recording, but the mic is paused (a call has it): the widgets say "paused" and stop counting.
    var isPaused: Bool { recordingSince != nil && pausedAt != nil }
}

struct StatusWidgetView: View {
    @Environment(\.widgetFamily) private var family
    var entry: StatusEntry

    var body: some View {
        Group {
            switch family {
            case .accessoryCircular: LockCircular(status: entry.status, stale: entry.stale)
            case .accessoryRectangular: LockRectangular(status: entry.status, now: entry.date, stale: entry.stale)
            case .accessoryInline: LockInline(status: entry.status, stale: entry.stale)
            default: HomeSmall(status: entry.status, now: entry.date, stale: entry.stale)
            }
        }
        // A tap opens the app straight into recording. The link carries this device's key (`LinkKey`): the app starts
        // the mic only for a link that has it. While it shows a recording (live, paused or gone stale) a tap only opens
        // the app: after a crash the app would otherwise start a brand-new recording when he only meant to check.
        .widgetURL(entry.status.recordingSince == nil ? DeepLink.record.url : nil)
        .containerBackground(for: .widget) {
            // The system background on the Home Screen (white or black); the Lock Screen draws its own.
            if family == .systemSmall { Rectangle().fill(.background) } else { Color.clear }
        }
    }
}

// MARK: - Lock Screen

// The Lock Screen draws these in one tint, so they use the system's primary and secondary, not the theme's colours.

/// The record mark (a dot in a ring); while it records a wave and the length under it (a pause sign and the length
/// it stopped at while the mic is paused), and while recordings wait a count. Gone stale (the app stopped saying
/// it's alive): a crossed-out mic, and the length only if it was paused.
struct LockCircular: View {
    var status: SharedStatus
    var stale = false

    private var symbol: String {
        if stale && status.recordingSince != nil { return "mic.slash" }
        if status.isPaused { return "pause" }
        return status.recordingSince != nil ? "waveform" : "record.circle"
    }

    var body: some View {
        ZStack {
            AccessoryWidgetBackground()
            VStack(spacing: 0) {
                Image(systemName: symbol).font(.title2)
                if stale, status.recordingSince != nil {
                    if let since = status.recordingSince, let paused = status.pausedAt {
                        ElapsedText(startedAt: since, stoppedAt: paused)
                            .font(.caption2.weight(.semibold).monospacedDigit())
                            .lineLimit(1)
                            .minimumScaleFactor(0.7)
                            .frame(width: 48)
                    }
                } else if let since = status.recordingSince {
                    ElapsedText(startedAt: since, stoppedAt: status.pausedAt)
                        .font(.caption2.weight(.semibold).monospacedDigit())
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                        .frame(width: 48)
                } else if status.waiting > 0 {
                    Text("\(status.waiting)").font(.caption.weight(.semibold).monospacedDigit())
                }
            }
        }
    }
}

/// "Sona", then what you'd want to know: the length while it records (stopped, with "Paused", while the mic is),
/// otherwise the newest note's title (or "Tap to record" when there is none), with how many are waiting, or when the
/// newest note was made, on the right. Gone stale: "Not recording", and "Open Sona" (or the length it paused at).
struct LockRectangular: View {
    var status: SharedStatus
    var now: Date
    var stale = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 4) {
                Text("Sona").fontWeight(.semibold)
                Spacer(minLength: 4)
                if status.recordingSince != nil {
                    Text(stale ? "Not recording" : status.isPaused ? "Paused" : "Recording")
                } else if status.waiting > 0 {
                    Text("\(status.waiting) waiting")
                } else if let at = status.latestAt {
                    Text(WidgetFormat.when(at, now: now))
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            .lineLimit(1)

            if stale, let since = status.recordingSince {
                // No running timer: there's no length to trust once the app may have died.
                if let paused = status.pausedAt {
                    ElapsedText(startedAt: since, stoppedAt: paused)
                        .font(.title2.weight(.semibold).monospacedDigit())
                        .lineLimit(1)
                        .minimumScaleFactor(0.6)
                } else {
                    Text("Open Sona").font(.subheadline.weight(.semibold))
                }
            } else if let since = status.recordingSince {
                ElapsedText(startedAt: since, stoppedAt: status.pausedAt)
                    .font(.title2.weight(.semibold).monospacedDigit())
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
            } else if let title = status.latestTitle {
                // A note's title can be personal; the Lock Screen blanks it until the phone is unlocked.
                Text(title).font(.subheadline.weight(.semibold)).lineLimit(2).privacySensitive()
            } else {
                Text("Tap to record").font(.subheadline.weight(.semibold))
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// One line next to the date.
struct LockInline: View {
    var status: SharedStatus
    var stale = false

    var body: some View {
        if stale, status.recordingSince != nil {
            Label("Sona: not recording", systemImage: "mic.slash")
        } else if let since = status.recordingSince, let paused = status.pausedAt {
            Label("Sona: paused \(WidgetFormat.duration(paused.timeIntervalSince(since)))", systemImage: "pause")
        } else if let since = status.recordingSince {
            Label {
                Text("Sona: recording \(Text(timerInterval: since...Date.distantFuture, countsDown: false))")
            } icon: {
                Image(systemName: "waveform")
            }
        } else if status.waiting > 0 {
            Label("Sona: \(status.waiting) waiting", systemImage: "record.circle")
        } else {
            Label("Sona: tap to record", systemImage: "record.circle")
        }
    }
}

// MARK: - Home Screen

/// The small widget: the record button, the newest note's title and when, and how many are waiting. While it records
/// the length takes the title's place; while the mic is paused the length stops, under "Paused". Gone stale (the app
/// stopped saying it's alive): "Not recording" with "Open Sona" (or the length it paused at).
struct HomeSmall: View {
    var status: SharedStatus
    var now: Date
    var stale = false
    @Environment(\.widgetRenderingMode) private var mode

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top) {
                RecordTarget(recording: status.recordingSince != nil && !status.isPaused && !stale)
                Spacer(minLength: 4)
                if status.waiting > 0 { Meta("\(status.waiting) waiting") }
            }
            Spacer(minLength: 8)
            bottom
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    @ViewBuilder private var bottom: some View {
        if stale, let since = status.recordingSince {
            VStack(alignment: .leading, spacing: 4) {
                Meta("Not recording")
                if let paused = status.pausedAt {
                    ElapsedText(startedAt: since, stoppedAt: paused)
                        .font(.title.weight(.semibold).monospacedDigit())
                        .foregroundStyle(mode.grey)
                        .lineLimit(1)
                        .minimumScaleFactor(0.6)
                } else {
                    Text("Open Sona").font(.subheadline.weight(.semibold)).foregroundStyle(mode.ink)
                }
            }
        } else if let since = status.recordingSince {
            VStack(alignment: .leading, spacing: 4) {
                Meta(status.isPaused ? "Paused" : "Recording")
                ElapsedText(startedAt: since, stoppedAt: status.pausedAt)
                    .font(.title.weight(.semibold).monospacedDigit())
                    .foregroundStyle(mode.ink)
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
            }
        } else if let title = status.latestTitle {
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(mode.ink)
                    .lineLimit(2)
                    .privacySensitive()
                if let at = status.latestAt { Meta(WidgetFormat.when(at, now: now)) }
            }
        } else {
            Text("Tap to record").font(.subheadline.weight(.semibold)).foregroundStyle(mode.grey)
        }
    }
}

/// The record button, as in the app: a red dot in a ring (red is only ever recording). While it records the ring is
/// red too. A tinted Home Screen has no colours to give, so there the dot and ring take its tint.
struct RecordTarget: View {
    var recording: Bool
    @Environment(\.widgetRenderingMode) private var renderingMode

    var body: some View {
        let full = renderingMode == .fullColor
        ZStack {
            Circle().strokeBorder(full && recording ? AnyShapeStyle(SonaTheme.accent) : AnyShapeStyle(.primary), lineWidth: 3)
            Circle()
                .fill(full ? AnyShapeStyle(SonaTheme.accent) : AnyShapeStyle(.primary))
                .padding(8)
        }
        .frame(width: 48, height: 48)
        .widgetAccentable()
    }
}
