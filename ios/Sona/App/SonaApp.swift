import SwiftUI
import UIKit

@main
struct SonaApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @State private var model = AppModel.shared
    @Environment(\.scenePhase) private var phase

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(model)
                .onOpenURL { model.handle($0) }
                .onChange(of: phase) { before, now in model.phaseChanged(from: before, to: now) }
        }
    }
}

/// Launch work that must also run when there's no screen: the Record button, Siri or the watch can launch the app
/// in the background, and that still has to receive the watch's files and transcribe.
final class AppDelegate: NSObject, UIApplicationDelegate {
    func application(_ application: UIApplication, didFinishLaunchingWithOptions options: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        // Before launch finishes, or iOS never hands the app its charging-time transcription task.
        NotesService.registerBackgroundTask()
        AppModel.shared.launch()
        return true
    }
}
