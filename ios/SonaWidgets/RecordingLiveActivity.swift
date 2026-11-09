import ActivityKit
import AppIntents
import SwiftUI
import WidgetKit

/// The Live Activity while the iPhone records: a Lock Screen banner and the Dynamic Island. The timer counts by
/// itself (`Text(timerInterval:)`). The app updates this when the mic pauses and comes back, when it stops ("saved",
/// or why it stopped by itself), and once a minute in between. If those updates stop coming (the app died, or iOS
/// suspended it while a call had the mic), the system marks it stale and it says it isn't recording.
struct RecordingLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: RecordingAttributes.self) { context in
            // No background tint: the system's own is solid white on a light Lock Screen and solid black on a dark
            // one, decided with the same appearance the banner's text reads (`BannerColors`). A tint of our own,
            // even a light/dark one, is resolved apart from the content and can stay on the other appearance (an
            // ActivityKit bug Apple knows about), leaving dark text on black or white on white.
            RecordingBanner(state: context.state, isStale: context.isStale)
        } dynamicIsland: { context in
            let state = context.state
            let look = state.look(isStale: context.isStale)
            return DynamicIsland {
                // What it's doing on the left of the camera, Stop on the right, the length big under it, and the
                // voice wave under that while it records.
                DynamicIslandExpandedRegion(.leading) { IslandStatus(look: look) }
                DynamicIslandExpandedRegion(.trailing) {
                    if !look.hasEnded { StopButton(inIsland: true) }
                }
                DynamicIslandExpandedRegion(.center) { IslandTimer(state: state, look: look) }
                DynamicIslandExpandedRegion(.bottom) {
                    if !look.hasEnded { IslandWave(state: state, look: look) }
                }
            } compactLeading: {
                IslandCompactLeading(look: look, levels: state.levels)
            } compactTrailing: {
                IslandCompactTrailing(state: state, look: look)
            } minimal: {
                IslandMinimal(look: look)
            }
            .keylineTint(look == .recording ? SonaTheme.accent : Color.gray)
        }
    }
}

extension RecordingAttributes.ContentState.Look {
    var hasEnded: Bool {
        switch self {
        case .saved, .stopped: true
        case .recording, .paused, .notRecording: false
        }
    }

    /// Paused, not recording, or stopped by itself: said in full ink rather than grey (red is only ever recording).
    var isProblem: Bool {
        switch self {
        case .paused, .notRecording, .stopped: true
        case .recording, .saved: false
        }
    }

    /// One or two words, for the island.
    var word: String {
        switch self {
        case .recording: "Recording"
        case .paused: "Paused"
        case .notRecording: "Not recording"
        case .saved: "Saved"
        case .stopped: "Stopped"
        }
    }

    /// The Lock Screen's status line, with room for what to do and why. A tap on the banner opens Sona, which gets
    /// the mic back if the call is over.
    var line: String {
        switch self {
        case .paused: "Paused, tap to carry on"
        case .notRecording: "Not recording, tap to open"
        case .stopped(let reason): "Stopped: \(reason)"
        case .recording, .saved: word
        }
    }
}

/// The red dot while it records (red is only ever recording); a grey ring (an outline: it's meant to be recording
/// but hears nothing) while it's paused, not recording or stopped by itself; nothing once it's saved.
struct StatusMark: View {
    var look: RecordingAttributes.ContentState.Look

    var body: some View {
        switch look {
        case .recording: RecordingDot()
        case .paused, .notRecording, .stopped: RingDot()
        case .saved: EmptyView()
        }
    }
}

/// The length: counting while it records, stopped where the mic paused, the final length once it's over. Not
/// recording with no pause to go by (the app died), there's no length to trust, so it says `unknown` instead.
struct ActivityLength: View {
    var state: RecordingAttributes.ContentState
    var look: RecordingAttributes.ContentState.Look
    var unknown = "Open Sona"

    var body: some View {
        switch look {
        case .recording:
            ElapsedText(startedAt: state.startedAt, stoppedAt: nil)
        case .paused, .notRecording:
            if let pausedAt = state.pausedAt {
                ElapsedText(startedAt: state.startedAt, stoppedAt: pausedAt)
            } else {
                Text(unknown)
            }
        case .saved, .stopped:
            ElapsedText(startedAt: state.startedAt, stoppedAt: state.stoppedAt ?? state.startedAt)
        }
    }
}

// MARK: - Lock Screen

/// The Lock Screen banner's colours, from the appearance the system draws it in: ink on its white background, white
/// on its black one. Not the app's warm paper: on a real Lock Screen that read as yellow (7 Nov 2026). The only
/// colour is the system red, and only for recording (`SonaTheme.accent`).
enum BannerColors {
    static func ink(_ scheme: ColorScheme) -> Color { scheme == .dark ? .white : .black }
    /// What the system draws behind the banner, for the snapshots (the activity itself sets none).
    static func background(_ scheme: ColorScheme) -> Color { scheme == .dark ? .black : .white }
}

/// The Lock Screen banner: what it's doing and the running length on the left, Stop on the right, and under them the
/// last few seconds of the voice as a red wave, so it's plain the mic is hearing. Paused or not recording, the
/// length stops, in grey, under a grey ring and what to do, the wave goes flat and grey, and Stop stays. Once it's
/// stopped it says "Saved" (or why it stopped) with the final length, and no button or wave.
struct RecordingBanner: View {
    var state: RecordingAttributes.ContentState
    var isStale = false
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let look = state.look(isStale: isStale)
        let ink = BannerColors.ink(scheme)
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 8) {
                        StatusMark(look: look)
                        Text(look.line)
                            .font(.subheadline)
                            .foregroundStyle(look.isProblem ? ink : Color.secondary)
                            .lineLimit(1)
                            .minimumScaleFactor(0.75)
                    }
                    ActivityLength(state: state, look: look, unknown: "Open Sona")
                        .font(.largeTitle.weight(.semibold).monospacedDigit())
                        .foregroundStyle(look == .paused || look == .notRecording ? Color.secondary : ink)
                        .lineLimit(1)
                        .minimumScaleFactor(0.6)
                }
                // The timer text asks for room for the longest time it could ever show, so it's given what's left
                // and no more.
                .frame(maxWidth: .infinity, alignment: .leading)
                if !look.hasEnded { StopButton(inIsland: false) }
            }
            if !look.hasEnded {
                WaveBars(
                    levels: look == .recording ? state.levels : nil,
                    color: look == .recording ? SonaTheme.accent : Color.secondary)
                    .frame(height: 28)
            }
        }
        .padding(16)
    }
}

/// Stop: the one button, a red capsule with white text, since it belongs to the recording (red is only ever
/// recording). A little smaller in the island.
struct StopButton: View {
    var inIsland: Bool

    var body: some View {
        Button(intent: StopRecordingIntent()) {
            HStack(spacing: 4) {
                Image(systemName: "stop.fill").font(.caption)
                Text("Stop").font(.subheadline.weight(.semibold))
            }
            .foregroundStyle(.white)
            .padding(.horizontal, inIsland ? 12 : 16)
            .padding(.vertical, inIsland ? 8 : 12)
            .background(Capsule().fill(SonaTheme.accent))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
    }
}

/// The last few seconds of the voice as bars, newest on the right (`ActivityWave`). A Live Activity can't animate on
/// its own, so the bars move when the app's next update lands, every few seconds. Quiet bars are faint dots, so a
/// pause still reads as listening.
struct WaveBars: View {
    var levels: [UInt8]?
    var bars = ActivityWave.count
    var color: Color
    var gap: CGFloat = 3

    var body: some View {
        GeometryReader { geo in
            let heights = ActivityWave.heights(levels, bars: bars)
            let width = max(1, (geo.size.width - gap * CGFloat(bars - 1)) / CGFloat(bars))
            HStack(alignment: .center, spacing: gap) {
                ForEach(heights.indices, id: \.self) { i in
                    Capsule()
                        .fill(color.opacity(heights[i] > 0.02 ? 1 : 0.3))
                        .frame(width: width, height: max(width, geo.size.height * heights[i]))
                }
            }
            .frame(width: geo.size.width, height: geo.size.height)
        }
        .accessibilityHidden(true)
    }
}

// MARK: - Dynamic Island

// The island is always black, so its text is white, with the same grey for status and the same red for recording.

/// Expanded, left: what it's doing.
struct IslandStatus: View {
    var look: RecordingAttributes.ContentState.Look

    var body: some View {
        HStack(spacing: 8) {
            StatusMark(look: look)
            Text(look.word)
                .font(.caption.weight(.semibold))
                .foregroundStyle(look.isProblem ? Color.white : Color.secondary)
                .lineLimit(1)
                .minimumScaleFactor(0.75)
        }
    }
}

/// Expanded, middle: the length, big; grey while it isn't counting.
struct IslandTimer: View {
    var state: RecordingAttributes.ContentState
    var look: RecordingAttributes.ContentState.Look

    var body: some View {
        ActivityLength(state: state, look: look, unknown: "Open Sona")
            .font(.title.weight(.semibold).monospacedDigit())
            .foregroundStyle(look == .recording || look.hasEnded ? Color.white : Color.secondary)
            .lineLimit(1)
            .minimumScaleFactor(0.5)
            // The length before the wave under it: the wave can be shorter, the time can't.
            .layoutPriority(1)
    }
}

/// Expanded, bottom: the voice wave while it records, flat and grey while it hears nothing.
struct IslandWave: View {
    var state: RecordingAttributes.ContentState
    var look: RecordingAttributes.ContentState.Look

    var body: some View {
        WaveBars(
            levels: look == .recording ? state.levels : nil,
            color: look == .recording ? SonaTheme.accent : Color.secondary)
            .frame(height: 22)
            .padding(.horizontal, 8)
            .padding(.top, 4)
    }
}

/// Compact, left: a little red wave while it records (a red mic until the first levels come), a white pause or
/// crossed-out mic while it hears nothing, a white "!" when it stopped by itself, a grey tick once it's saved.
struct IslandCompactLeading: View {
    var look: RecordingAttributes.ContentState.Look
    var levels: [UInt8]? = nil

    private var symbol: String {
        switch look {
        case .recording: "mic.fill"
        case .paused: "pause.fill"
        case .notRecording: "mic.slash.fill"
        case .saved: "checkmark"
        case .stopped: "exclamationmark"
        }
    }

    var body: some View {
        // The wave only while it hears something: five faint dots in silence read as nothing at all, the mic doesn't.
        if look == .recording, let levels, !ActivityWave.isQuiet(levels.suffix(5)) {
            WaveBars(levels: levels, bars: 5, color: SonaTheme.accent, gap: 2)
                .frame(width: 20, height: 14)
        } else {
            Image(systemName: symbol)
                .font(.footnote)
                .foregroundStyle(look == .recording ? SonaTheme.accent : look == .saved ? Color.secondary : Color.white)
        }
    }
}

/// Compact, right: the length, in a fixed width with digits that all measure the same. Without the width the timer
/// text claims room for the longest time it could ever show and stretches the island.
struct IslandCompactTrailing: View {
    var state: RecordingAttributes.ContentState
    var look: RecordingAttributes.ContentState.Look

    var body: some View {
        ActivityLength(state: state, look: look, unknown: "Off")
            .font(.footnote.weight(.semibold).monospacedDigit())
            .foregroundStyle(look == .recording ? Color.white : Color.secondary)
            .lineLimit(1)
            .minimumScaleFactor(0.7)
            .frame(width: 44, alignment: .trailing)
    }
}

/// Minimal (another activity has the island too): the red dot while it records, a grey ring while it hears nothing
/// or stopped by itself, grey once it's saved.
struct IslandMinimal: View {
    var look: RecordingAttributes.ContentState.Look

    var body: some View {
        switch look {
        case .recording: Circle().fill(SonaTheme.accent).frame(width: 10, height: 10)
        case .saved: Circle().fill(Color.secondary).frame(width: 10, height: 10)
        case .paused, .notRecording, .stopped: RingDot(size: 10)
        }
    }
}
