import CoreLocation
import Foundation

final class BackgroundKeepAlive: NSObject, CLLocationManagerDelegate {
    private let manager = CLLocationManager()
    private(set) var lastKnownCoordinate: CLLocationCoordinate2D?
    private var lastKnownAccuracy = CLLocationAccuracy.greatestFiniteMagnitude
    private var lastKnownDate = Date.distantPast
    private var ignoreFixesBefore: Date?

    private let maxFixAge: TimeInterval = 10
    private let coarseFixGrace: TimeInterval = 30

    override init() {
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyBest
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

    /// Full accuracy finds the real position; a simulated session only needs keep-alive.
    func useHighAccuracy(_ enabled: Bool) {
        manager.desiredAccuracy = enabled ? kCLLocationAccuracyBest : kCLLocationAccuracyThreeKilometers
    }

    /// Drops the spoofed fix and restarts updates. startUpdatingLocation alone is a
    /// no-op while running, so the real position would not arrive at this accuracy.
    func refreshAfterSimulation() {
        lastKnownCoordinate = nil
        lastKnownAccuracy = .greatestFiniteMagnitude
        lastKnownDate = .distantPast
        ignoreFixesBefore = Date()
        manager.stopUpdatingLocation()
        useHighAccuracy(true)
        manager.requestAlwaysAuthorization()
        manager.startUpdatingLocation()
    }

    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let location = locations.last,
              location.sourceInformation?.isSimulatedBySoftware != true,
              location.horizontalAccuracy >= 0,
              location.timestamp.timeIntervalSinceNow > -maxFixAge else { return }
        if let ignoreFixesBefore {
            guard location.timestamp > ignoreFixesBefore else { return }
            self.ignoreFixesBefore = nil
        }
        // A coarse cell / Wi-Fi fix must not replace a recent GPS fix.
        let isCoarser = location.horizontalAccuracy > lastKnownAccuracy
        guard !isCoarser || location.timestamp.timeIntervalSince(lastKnownDate) > coarseFixGrace else { return }
        lastKnownCoordinate = location.coordinate
        lastKnownAccuracy = location.horizontalAccuracy
        lastKnownDate = location.timestamp
    }
}
