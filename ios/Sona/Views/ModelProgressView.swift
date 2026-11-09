import SwiftUI

/// The slim bar while the speech model downloads by itself: "Downloading the local speech model, please wait... 42%".
/// On Home (with `showsKeepOpen`) and on every onboarding step after the welcome. No button: it starts, picks up and
/// tries again on its own.
struct ModelProgressView: View {
    var progress: ModelProgress
    /// Home: say to keep the app open, and that recording works meanwhile.
    var showsKeepOpen = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(progress.text)
                .font(.footnote)
                .monospacedDigit()
                // Not red even when it stopped: red is only for recording, and the words say it stopped.
                .foregroundStyle(Color.primary)
            if let fraction = progress.fraction {
                ProgressView(value: fraction)
                    .progressViewStyle(.linear)
                    .tint(.primary)
                    .accessibilityHidden(true)
            }
            // Waiting for space it isn't downloading, so "keep Sona open" would be wrong.
            if showsKeepOpen, !progress.waitsForSpace {
                Text(ModelProgress.keepOpen)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .combine)
    }
}
