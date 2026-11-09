import SwiftUI
import WidgetKit

@main
struct SonaWidgetsBundle: WidgetBundle {
    var body: some Widget {
        RecordingLiveActivity()
        RecordControl()
        StatusWidget()
    }
}
