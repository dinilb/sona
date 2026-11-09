import SwiftUI
import UIKit

/// The record button floating at the bottom of Home: a red circle on glass, the one colour on the screen. A start that
/// failed (the mic is off for Sona, say) says why just above it.
struct RecordButton: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(spacing: 8) {
            if let error = model.recordingError {
                VStack(spacing: 4) {
                    Text(error)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                    if model.micDenied, let settings = URL(string: UIApplication.openSettingsURLString) {
                        Link("Open Settings", destination: settings)
                            .font(.footnote.weight(.semibold))
                            .tint(.primary)
                    }
                }
                .padding(.horizontal, 32)
            }
            GlassEffectContainer {
                Button {
                    Task { await model.startRecording() }
                } label: {
                    Circle().fill(SonaTheme.accent).frame(width: 56, height: 56).padding(8)
                }
                .buttonStyle(.plain)
                .glassEffect(.regular.interactive(), in: .circle)
                .accessibilityLabel("Record")
            }
        }
    }
}

/// Home's bottom bar while it records, under the recording sheet: Stop stays on Home even when the sheet can't come up
/// (another sheet, a confirm or an alert was showing when a recording started from the Lock Screen, Siri or the Action
/// button). Red only for the recording: the dot and Stop.
struct RecordingBar: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let paused = model.pausedAt != nil
        GlassEffectContainer {
            HStack(spacing: 12) {
                Circle()
                    .fill(paused ? Color.secondary : SonaTheme.accent)
                    .frame(width: 12, height: 12)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 0) {
                    Text(paused ? "Paused" : "Recording")
                        .font(.headline)
                    if let started = model.recordingStartedAt {
                        Text(timerInterval: started...Date.distantFuture, pauseTime: model.pausedAt, countsDown: false)
                            .font(.subheadline)
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                    }
                }
                .accessibilityElement(children: .combine)
                Spacer(minLength: 8)
                Button {
                    Task { await model.stopRecording() }
                } label: {
                    RoundedRectangle(cornerRadius: 4)
                        .fill(SonaTheme.accent)
                        .frame(width: 20, height: 20)
                        .frame(width: 44, height: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Stop")
            }
            .padding(.leading, 20)
            .padding(.trailing, 8)
            .padding(.vertical, 8)
            .glassEffect(.regular, in: .capsule)
        }
    }
}

/// While it records, like Voice Memos' new recording: the time, the live wave and Stop. While a call or Siri has the
/// mic it says paused, the time stands still and the wave goes flat (it carries on by itself, and the gap is kept as
/// silence). Red only for the recording itself: the wave and Stop.
struct RecordingSheet: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let paused = model.pausedAt != nil
        VStack(spacing: 4) {
            Text(paused ? "Paused" : "New recording")
                .font(.title3.weight(.semibold))
                .padding(.top, 24)
            if let started = model.recordingStartedAt {
                Text(timerInterval: started...Date.distantFuture, pauseTime: model.pausedAt, countsDown: false)
                    .font(.subheadline)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
            Waveform(
                wave: paused ? WaveScroll() : model.wave, bars: 64, gap: 2,
                color: paused ? Color.secondary : SonaTheme.accent
            )
            .frame(height: 64)
            .padding(.horizontal, 16)
            .padding(.vertical, 16)
            if let error = model.recordingError {
                Text(error)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 32)
                    .padding(.bottom, 8)
            }
            Spacer(minLength: 0)
            Button {
                Task { await model.stopRecording() }
            } label: {
                ZStack {
                    Circle().strokeBorder(Color(uiColor: .systemGray3), lineWidth: 4).frame(width: 68, height: 68)
                    RoundedRectangle(cornerRadius: 8).fill(SonaTheme.accent).frame(width: 28, height: 28)
                }
                .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Stop")
            .padding(.bottom, 24)
        }
        .frame(maxWidth: .infinity)
    }
}
