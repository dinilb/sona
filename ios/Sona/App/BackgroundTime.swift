import UIKit

/// Background time for one piece of work, given back when it's done or when iOS says time is up. Ending it twice is
/// fine.
@MainActor
final class BackgroundTime {
    private var task: UIBackgroundTaskIdentifier = .invalid

    /// `onExpire`: iOS says time is up; it runs first, then the time is given back.
    init(name: String, onExpire: (@MainActor @Sendable (BackgroundTime) -> Void)? = nil) {
        task = UIApplication.shared.beginBackgroundTask(withName: name) { [weak self] in
            guard let self else { return }
            onExpire?(self)
            self.end()
        }
    }

    func end() {
        guard task != .invalid else { return }
        UIApplication.shared.endBackgroundTask(task)
        task = .invalid
    }
}
