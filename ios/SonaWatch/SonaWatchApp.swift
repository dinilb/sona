import SwiftUI

@main
struct SonaWatchApp: App {
    @Environment(\.scenePhase) private var scenePhase
    private let model = AppModel.shared

    var body: some Scene {
        WindowGroup {
            MainView()
                .environment(model)
                .onOpenURL { model.open($0) }
        }
        .onChange(of: scenePhase) { _, phase in model.phaseChanged(phase) }
        // The iPhone's acknowledgement (or inventory) can arrive with the app in the background: without this the
        // task ends at once and the watch keeps saying "1 waiting" until Sona is opened.
        .backgroundTask(.watchConnectivity) { await AppModel.drainConnectivity() }
    }
}
