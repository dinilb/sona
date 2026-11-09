import CoreLocation
import Foundation
import NotesKit

/// One location fix: `CLLocationManager.requestLocation()`, which gets a single fix and then stops location services by
/// itself, waited for at most `timeout`. If iOS refuses a live fix (a start or stop from the Lock Screen, Siri or the
/// Live Activity: the app isn't "in use" then, and there's no location background mode), a fix Core Location already
/// had from around that moment stands in; otherwise there's none. It never asks for permission (callers check first).
/// Created on the main thread, so Core Location calls it back there.
final class OneShotFix: NSObject, CLLocationManagerDelegate {
    private let manager = CLLocationManager()
    private var waiting: CheckedContinuation<CLLocation?, Never>?
    private var timer: Task<Void, Never>?

    override init() {
        super.init()
        manager.delegate = self
        // A street, without a minute of GPS.
        manager.desiredAccuracy = kCLLocationAccuracyNearestTenMeters
    }

    /// False with Approximate Location.
    var precise: Bool { manager.accuracyAuthorization == .fullAccuracy }

    func fix(near moment: Date, timeout: Duration) async -> CLLocation? {
        guard waiting == nil else { return nil }
        let live: CLLocation? = await withCheckedContinuation { continuation in
            waiting = continuation
            manager.requestLocation()
            timer = Task { [weak self] in
                try? await Task.sleep(for: timeout)
                self?.finish(nil)
            }
        }
        if let live, live.horizontalAccuracy >= 0 { return live }
        if let cached = manager.location,
            PlaceRules.usableCached(at: cached.timestamp, accuracy: cached.horizontalAccuracy, moment: moment)
        {
            return cached
        }
        return nil
    }

    private func finish(_ location: CLLocation?) {
        guard let waiting else { return }
        self.waiting = nil
        timer?.cancel()
        timer = nil
        manager.stopUpdatingLocation()  // a requestLocation still pending stops here
        waiting.resume(returning: location)
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        let last = locations.last
        Task { @MainActor in self.finish(last) }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didFailWithError error: any Error) {
        // .denied: not "in use" (the background). .locationUnknown: no fix in time. Only the code, never a place.
        let code = (error as NSError).code
        Task { @MainActor in
            Log.note("places: no live fix (location error \(code))")
            self.finish(nil)
        }
    }
}
