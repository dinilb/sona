#if DEBUG
import ActivityKit
import SwiftUI
import WidgetKit

// Xcode previews of the Live Activity and the widgets in their sample states. Debug builds only.
// (`scripts/widget-snapshots.sh` draws the same views to PNGs without Xcode.)

#Preview("Live Activity: Lock Screen", as: .content, using: RecordingAttributes()) {
    RecordingLiveActivity()
} contentStates: {
    RecordingAttributes.ContentState.sampleRecording
    RecordingAttributes.ContentState.sampleSaved
    RecordingAttributes.ContentState.sampleLong
}

#Preview("Live Activity: island, expanded", as: .dynamicIsland(.expanded), using: RecordingAttributes()) {
    RecordingLiveActivity()
} contentStates: {
    RecordingAttributes.ContentState.sampleRecording
    RecordingAttributes.ContentState.sampleSaved
}

#Preview("Live Activity: island, compact", as: .dynamicIsland(.compact), using: RecordingAttributes()) {
    RecordingLiveActivity()
} contentStates: {
    RecordingAttributes.ContentState.sampleRecording
    RecordingAttributes.ContentState.sampleLong
    RecordingAttributes.ContentState.sampleSaved
}

#Preview("Live Activity: island, minimal", as: .dynamicIsland(.minimal), using: RecordingAttributes()) {
    RecordingLiveActivity()
} contentStates: {
    RecordingAttributes.ContentState.sampleRecording
    RecordingAttributes.ContentState.sampleSaved
}

#Preview("Home Screen, small", as: .systemSmall) {
    StatusWidget()
} timeline: {
    StatusEntry(date: .now, status: .sampleIdle)
    StatusEntry(date: .now, status: .sampleNote)
    StatusEntry(date: .now, status: .sampleWaiting)
    StatusEntry(date: .now, status: .sampleLongTitle)
    StatusEntry(date: .now, status: .sampleRecording)
}

#Preview("Lock Screen, circular", as: .accessoryCircular) {
    StatusWidget()
} timeline: {
    StatusEntry(date: .now, status: .sampleIdle)
    StatusEntry(date: .now, status: .sampleWaiting)
    StatusEntry(date: .now, status: .sampleRecording)
}

#Preview("Lock Screen, rectangular", as: .accessoryRectangular) {
    StatusWidget()
} timeline: {
    StatusEntry(date: .now, status: .sampleIdle)
    StatusEntry(date: .now, status: .sampleNote)
    StatusEntry(date: .now, status: .sampleWaiting)
    StatusEntry(date: .now, status: .sampleLongTitle)
    StatusEntry(date: .now, status: .sampleRecording)
}

#Preview("Lock Screen, inline", as: .accessoryInline) {
    StatusWidget()
} timeline: {
    StatusEntry(date: .now, status: .sampleIdle)
    StatusEntry(date: .now, status: .sampleWaiting)
    StatusEntry(date: .now, status: .sampleRecording)
}
#endif
