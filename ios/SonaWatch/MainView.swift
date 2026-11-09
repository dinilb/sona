import SwiftUI

/// One big button (a red dot in a ring, like Voice Memos; a square to stop), the status line under it, and a page
/// down (the crown or a swipe), the last few recordings. Pages rather than one scroll, so no half a row peeks in under
/// the button on any watch size. White on black like the rest of watchOS, in system type; red (`SonaTheme.accent`)
/// only for recording: the button, the live wave and a recording's row. Problems are said in plain white.
struct MainView: View {
    @Environment(AppModel.self) private var model
    @State private var page = MainView.firstPage

    var body: some View {
        TabView(selection: $page) {
            RecordPage(recorder: model.recorder, status: model.status)
                .tag(0)
            if !model.recent.isEmpty {
                ScrollView { RecentList(rows: model.recent) }
                    .tag(1)
            }
        }
        .tabViewStyle(.verticalPage)
        .background(Color.black)
        // Back to the button when recording starts or stops, wherever it came from (a link, double tap, Siri).
        .onChange(of: model.recorder.isRecording) { page = 0 }
    }

    private static var firstPage: Int {
        #if DEBUG
        // `-debugShowList` opens on the list, for screenshots in the simulator.
        if ProcessInfo.processInfo.arguments.contains("-debugShowList") { return 1 }
        #endif
        return 0
    }
}

/// The first screen: the button, and while recording the time and a live waveform above it.
private struct RecordPage: View {
    let recorder: WatchRecorder
    let status: String
    /// Wrist down (always-on): the waveform can't keep up at one frame a second, so it's hidden.
    @Environment(\.isLuminanceReduced) private var dimmed

    var body: some View {
        VStack(spacing: 6) {
            Spacer(minLength: 0)
            if recorder.isRecording, let startedAt = recorder.startedAt {
                Text(timerInterval: startedAt...Date.distantFuture, countsDown: false)
                    .font(.title.weight(.semibold))
                    .monospacedDigit()
                    .foregroundStyle(.white)
                Waveform(levels: recorder.levels)
                    .frame(height: 30)
                    .padding(.horizontal, 14)
                    .opacity(dimmed ? 0 : 1)
            }
            RecordButton(isRecording: recorder.isRecording, diameter: recorder.isRecording ? 72 : 112) {
                recorder.toggle()
            }
            Text(status)
                .font(.footnote)
                // A problem in full white, the rest grey: red is kept for recording.
                .foregroundStyle(recorder.message == nil ? Color.secondary : Color.primary)
                .multilineTextAlignment(.center)
                .lineLimit(3)
                .padding(.top, 2)
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity)
        .animation(.snappy, value: recorder.isRecording)
    }
}

private struct RecordButton: View {
    let isRecording: Bool
    let diameter: CGFloat
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            // Voice Memos' record button: a red dot in a light ring that becomes a rounded square (stop) while it
            // records.
            ZStack {
                Circle().strokeBorder(Color.white.opacity(0.85), lineWidth: max(3, diameter * 0.04))
                RoundedRectangle(cornerRadius: isRecording ? diameter * 0.1 : diameter, style: .continuous)
                    .fill(SonaTheme.accent)
                    .frame(
                        width: diameter * (isRecording ? 0.38 : 0.78), height: diameter * (isRecording ? 0.38 : 0.78))
            }
            .frame(width: diameter, height: diameter)
            .contentShape(Circle())
        }
        .buttonStyle(.plain)
        // Double tap (Series 9 and later) starts and stops too.
        .handGestureShortcut(.primaryAction)
        .accessibilityLabel(isRecording ? "Stop recording" : "Record")
    }
}

/// The input level as red bars, newest on the right; quiet bars (and the first seconds, before any level) are faint
/// dots, so a pause still reads as listening.
private struct Waveform: View {
    let levels: [Float]

    var body: some View {
        Canvas { context, size in
            let count = WatchRecorder.levelCount
            let gap: CGFloat = 2
            let width = max(1, (size.width - gap * CGFloat(count - 1)) / CGFloat(count))
            let recent = levels.suffix(count)
            let padded = Array(repeating: Float(0), count: count - recent.count) + recent
            for (index, level) in padded.enumerated() {
                let height = max(width, CGFloat(level) * size.height)
                let bar = CGRect(
                    x: CGFloat(index) * (width + gap), y: (size.height - height) / 2, width: width, height: height)
                let color = level > 0.02 ? SonaTheme.accent : SonaTheme.accent.opacity(0.35)
                context.fill(Path(roundedRect: bar, cornerRadius: width / 2), with: .color(color))
            }
        }
        .accessibilityHidden(true)
    }
}

/// The last few recordings: when, how long, and where they are.
private struct RecentList: View {
    let rows: [RecentRecording]

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(rows) { row in
                HStack(alignment: .firstTextBaseline) {
                    VStack(alignment: .leading, spacing: 1) {
                        Text(Self.when(row.recording.startedAt))
                            .font(.body)
                            .foregroundStyle(.white)
                        length(row)
                            .font(.footnote)
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 4)
                    Text(Self.label(row.state))
                        .font(.footnote)
                        .foregroundStyle(row.state == .recording ? SonaTheme.accent : Color.secondary)
                }
                .padding(.vertical, 7)
                .overlay(alignment: .bottom) { Rectangle().fill(Color.white.opacity(0.15)).frame(height: 0.5) }
            }
        }
        .padding(.leading, 4)
        .padding(.trailing, 14)  // clear of the page dots on the right edge
    }

    @ViewBuilder private func length(_ row: RecentRecording) -> some View {
        if row.state == .recording {
            Text(timerInterval: row.recording.startedAt...Date.distantFuture, countsDown: false)
        } else {
            Text(Duration.seconds(row.recording.duration.rounded(.down)).formatted(.time(pattern: .minuteSecond)))
        }
    }

    private static func when(_ date: Date) -> String {
        Calendar.current.isDateInToday(date)
            ? date.formatted(date: .omitted, time: .shortened)
            : date.formatted(.dateTime.weekday(.abbreviated).hour().minute())
    }

    private static func label(_ state: RecentRecording.State) -> String {
        switch state {
        case .recording: "Recording"
        case .waiting: "Waiting"
        case .sent: "Sent"
        }
    }
}
