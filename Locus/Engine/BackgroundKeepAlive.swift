import CoreLocation
import Foundation

final class BackgroundKeepAlive: NSObject, CLLocationManagerDelegate {
    private let manager = CLLocationManager()
    private(set) var lastKnownCoordinate: CLLocationCoordinate2D?
    private var ignoreFixesBefore: Date?

    override init() {
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyThreeKilometers
        manager.pausesLocationUpdatesAutomatically = false
        manager.allowsBackgroundLocationUpdates = true
        manager.showsBackgroundLocationIndicator = false
    }

    func start() {
        manager.requestAlwaysAuthorization()
        manager.startUpdatingLocation()
    }

    func stop() {
        manager.stopUpdatingLocation()
    }

    /// Drops the spoofed fix and restarts updates. startUpdatingLocation alone is a
    /// no-op while running, so the real position would not arrive at this accuracy.
    func refreshAfterSimulation() {
        lastKnownCoordinate = nil
        ignoreFixesBefore = Date()
        manager.stopUpdatingLocation()
        manager.desiredAccuracy = kCLLocationAccuracyBest
        manager.requestAlwaysAuthorization()
        manager.startUpdatingLocation()
    }

    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let location = locations.last,
              location.sourceInformation?.isSimulatedBySoftware != true else { return }
        if let ignoreFixesBefore {
            guard location.timestamp > ignoreFixesBefore else { return }
            self.ignoreFixesBefore = nil
            manager.desiredAccuracy = kCLLocationAccuracyThreeKilometers
        }
        lastKnownCoordinate = location.coordinate
    }
}
