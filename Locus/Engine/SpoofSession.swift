import CoreLocation
import Foundation
import MapKit
import SwiftUI
import UIKit
import UserNotifications

enum TravelMode: String, CaseIterable, Identifiable {
    case walk, run, cycle, drive

    var id: String { rawValue }

    var title: String {
        switch self {
        case .walk: return "Walk"
        case .run: return "Run"
        case .cycle: return "Cycle"
        case .drive: return "Drive"
        }
    }

    var icon: String {
        switch self {
        case .walk: return "figure.walk"
        case .run: return "figure.run"
        case .cycle: return "bicycle"
        case .drive: return "car.fill"
        }
    }

    /// Base meters per second before natural variation.
    var baseSpeed: CLLocationSpeed {
        switch self {
        case .walk: return 1.4
        case .run: return 3.3
        case .cycle: return 6.5
        case .drive: return 13.4
        }
    }

    var mkTransportType: MKDirectionsTransportType {
        switch self {
        case .walk, .run: return .walking
        case .cycle, .drive: return .automobile
        }
    }
}

enum SpoofStatus: Equatable {
    case idle
    case connecting
    case active
    case reconnecting
    case dropped(String)

    var label: String {
        switch self {
        case .idle: return "Not Spoofing"
        case .connecting: return "Starting…"
        case .active: return "Spoofing"
        case .reconnecting: return "Reconnecting…"
        case .dropped: return "Interrupted"
        }
    }

    var isDropped: Bool {
        if case .dropped = self { return true }
        return false
    }
}

@MainActor
final class SpoofSession: ObservableObject {
    @Published var status: SpoofStatus = .idle
    @Published var pin: CLLocationCoordinate2D?
    @Published var simulated: CLLocationCoordinate2D?
    @Published var travelMode: TravelMode = .walk
    @Published var mapStyleIndex: Int = 0
    @Published var lastError: String?
    @Published var isBusy = false
    @Published var joystickActive = false
    /// Bumped when the map should recenter, e.g. on the real position after a restore.
    @Published private(set) var recenterRevision = 0

    @Published var favorites: [SavedPlace] = []
    @Published var recents: [SavedPlace] = []
    @Published private(set) var home: SavedPlace?
    @Published var customSpeedEnabled = false {
        didSet { UserDefaults.standard.set(customSpeedEnabled, forKey: customSpeedEnabledKey) }
    }
    @Published var customSpeedKmh = SpoofSession.defaultCustomSpeedKmh {
        didSet {
            let clamped = min(max(customSpeedKmh, Self.customSpeedRange.lowerBound), Self.customSpeedRange.upperBound)
            if clamped != customSpeedKmh {
                customSpeedKmh = clamped
            } else {
                UserDefaults.standard.set(customSpeedKmh, forKey: customSpeedKey)
            }
        }
    }

    private var resendTimer: Timer?
    private var healthTimer: Timer?
    private var joystickTimer: Timer?
    private var routeTask: Task<Void, Never>?
    private var reconnectTask: Task<Void, Never>?
    private var resendInFlight = false
    private var backgroundTask = UIBackgroundTaskIdentifier.invalid
    private var joystickVector: CGVector = .zero
    private let locationKeeper = BackgroundKeepAlive()

    private let favoritesKey = "locus.favorites"
    private let recentsKey = "locus.recents"
    private let homeKey = "locus.home"
    private let activeSimulationKey = "locus.activeSimulation"
    private let customSpeedEnabledKey = "locus.customSpeedEnabled"
    private let customSpeedKey = "locus.customSpeedKmh"

    static let customSpeedRange: ClosedRange<Double> = 1...500
    private static let defaultCustomSpeedKmh = 30.0

    init() {
        favorites = SavedPlace.load(key: favoritesKey)
        recents = SavedPlace.load(key: recentsKey)
        home = SavedPlace.load(key: homeKey).first
        customSpeedEnabled = UserDefaults.standard.bool(forKey: customSpeedEnabledKey)
        if UserDefaults.standard.object(forKey: customSpeedKey) != nil {
            customSpeedKmh = UserDefaults.standard.double(forKey: customSpeedKey)
        }
    }

    var isSpoofing: Bool {
        if case .active = status { return true }
        if case .reconnecting = status { return true }
        return false
    }

    /// True while the device may still report a simulated location, including after a drop.
    var canRestore: Bool {
        isSpoofing || status.isDropped
    }

    /// Meters per second used by routes and the joystick.
    private var activeSpeed: CLLocationSpeed {
        customSpeedEnabled ? customSpeedKmh / 3.6 : travelMode.baseSpeed
    }

    func teleport(to coordinate: CLLocationCoordinate2D, pairing: PairingStore) {
        guard pairing.hasPairingFile else {
            lastError = "Import an RPPairing file in Settings first."
            return
        }
        routeTask?.cancel()
        routeTask = nil
        stopJoystick()
        pin = coordinate
        apply(coordinate, pairing: pairing, markRecent: true)
    }

    func stop(pairing: PairingStore) {
        routeTask?.cancel()
        routeTask = nil
        reconnectTask?.cancel()
        reconnectTask = nil
        stopJoystick()
        stopResend()
        stopHealth()
        isBusy = true
        let result = LocationEngine.clear(pairingPath: pairing.pairingPath, deviceIP: TunnelConfig.targetIP)
        isBusy = false
        switch result {
        case .success:
            simulated = nil
            pin = nil
            status = .idle
            lastError = nil
            SavedPlace.save([], key: activeSimulationKey)
            endBackground()
            // Force a fresh fix so the map puck / locate button return to the
            // real GPS position (not the leftover pin or last spoofed fix).
            locationKeeper.refreshAfterSimulation()
            recenterRevision += 1
        case .failure(let error):
            lastError = error.localizedDescription
            status = .dropped(error.localizedDescription)
            postDropNotification(error.localizedDescription)
        }
    }

    /// Picks up a simulation that was running when the app was closed.
    func resumeIfNeeded(pairing: PairingStore) {
        guard simulated == nil, pairing.hasPairingFile,
              let saved = SavedPlace.load(key: activeSimulationKey).first else { return }
        simulated = saved.coordinate
        pin = saved.coordinate
        locationKeeper.useHighAccuracy(false)
        locationKeeper.start()
        startResend(pairing: pairing)
        startHealth(pairing: pairing)
        startReconnect(pairing: pairing)
    }

    func handleScenePhase(_ phase: ScenePhase, pairing: PairingStore) {
        switch phase {
        case .active:
            startLocationUpdates()
            reconnectNow(pairing: pairing)
        case .background:
            if !canRestore {
                locationKeeper.stop()
            }
        default:
            break
        }
    }

    /// Retries at once, e.g. when the tunnel returns, instead of waiting out the backoff.
    func reconnectNow(pairing: PairingStore) {
        guard isSpoofing, !LocationEngine.isSessionActive else { return }
        reconnectTask?.cancel()
        reconnectTask = nil
        startReconnect(pairing: pairing)
    }

    func goHome(pairing: PairingStore) {
        guard let home else {
            lastError = "Set a Home address in Settings first."
            return
        }
        teleport(to: home.coordinate, pairing: pairing)
        recenterRevision += 1
    }

    func setHome(name: String, coordinate: CLLocationCoordinate2D) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let place = SavedPlace(
            name: trimmed.isEmpty ? Self.coordinateLabel(coordinate) : trimmed,
            latitude: coordinate.latitude,
            longitude: coordinate.longitude
        )
        home = place
        SavedPlace.save([place], key: homeKey)
    }

    func removeHome() {
        home = nil
        SavedPlace.save([], key: homeKey)
    }

    /// Best-known real device coordinate (not the teleport pin).
    var realCoordinate: CLLocationCoordinate2D? {
        locationKeeper.lastKnownCoordinate
    }

    /// Start lightweight GPS updates for the map puck / locate button.
    func startLocationUpdates() {
        locationKeeper.start()
    }

    func startJoystick(pairing: PairingStore) {
        guard pairing.hasPairingFile else {
            lastError = "Import an RPPairing file in Settings first."
            return
        }
        let start = simulated ?? pin ?? locationKeeper.lastKnownCoordinate
        guard let start else {
            lastError = "Drop a pin or teleport somewhere before using the joystick."
            return
        }
        if simulated == nil {
            apply(start, pairing: pairing, markRecent: false)
        }
        joystickActive = true
        joystickTimer?.invalidate()
        joystickTimer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.tickJoystick(pairing: pairing)
            }
        }
    }

    func updateJoystick(vector: CGVector) {
        joystickVector = vector
    }

    func stopJoystick() {
        joystickActive = false
        joystickVector = .zero
        joystickTimer?.invalidate()
        joystickTimer = nil
    }

    func followRoute(_ coordinates: [CLLocationCoordinate2D], pairing: PairingStore) {
        guard pairing.hasPairingFile, coordinates.count >= 2 else { return }
        routeTask?.cancel()
        stopJoystick()
        routeTask = Task { [weak self] in
            guard let self else { return }
            var previous = coordinates[0]
            await MainActor.run {
                self.apply(previous, pairing: pairing, markRecent: true)
            }
            for next in coordinates.dropFirst() {
                if Task.isCancelled { break }
                let distance = CLLocation(latitude: previous.latitude, longitude: previous.longitude)
                    .distance(from: CLLocation(latitude: next.latitude, longitude: next.longitude))
                let exactSpeed = self.customSpeedEnabled
                let speed = exactSpeed ? self.activeSpeed : max(0.8, self.activeSpeed * Double.random(in: 0.88...1.12))
                let stepMeters: CLLocationDistance = exactSpeed ? max(1, speed * 0.5) : min(12, max(4, speed * 0.5))
                let steps = max(1, Int(ceil(distance / stepMeters)))
                for i in 1...steps {
                    if Task.isCancelled { break }
                    let t = Double(i) / Double(steps)
                    let coord = CLLocationCoordinate2D(
                        latitude: previous.latitude + (next.latitude - previous.latitude) * t,
                        longitude: previous.longitude + (next.longitude - previous.longitude) * t
                    )
                    let delay = stepMeters / speed
                    try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
                    // A cancelled sleep returns at once; applying here would re-enable
                    // the simulation right after a restore.
                    while self.status == .reconnecting && !Task.isCancelled {
                        try? await Task.sleep(nanoseconds: 1_000_000_000)
                    }
                    if Task.isCancelled { break }
                    await MainActor.run {
                        self.apply(coord, pairing: pairing, markRecent: false)
                    }
                }
                previous = next
            }
        }
    }

    func addFavorite(name: String, coordinate: CLLocationCoordinate2D) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let place = SavedPlace(
            name: trimmed.isEmpty ? Self.coordinateLabel(coordinate) : trimmed,
            latitude: coordinate.latitude,
            longitude: coordinate.longitude
        )
        // Don't let a generic star overwrite a named favorite for the same spot.
        if let existing = favorites.first(where: { $0.id == place.id }),
           Self.isGenericFavoriteName(place.name),
           !Self.isGenericFavoriteName(existing.name) {
            return
        }
        favorites.removeAll { $0.id == place.id }
        favorites.insert(place, at: 0)
        SavedPlace.save(favorites, key: favoritesKey)
    }

    func renameFavorite(_ place: SavedPlace, to name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              let index = favorites.firstIndex(where: { $0.id == place.id }) else { return }
        favorites[index].name = trimmed
        SavedPlace.save(favorites, key: favoritesKey)
    }

    func removeFavorite(_ place: SavedPlace) {
        favorites.removeAll { $0.id == place.id }
        SavedPlace.save(favorites, key: favoritesKey)
    }

    func removeRecent(_ place: SavedPlace) {
        recents.removeAll { $0.id == place.id }
        SavedPlace.save(recents, key: recentsKey)
    }

    /// Best display name for starring the current pin (search title, matching recent, etc.).
    func suggestedFavoriteName(for coordinate: CLLocationCoordinate2D, fallback: String? = nil) -> String {
        if let fallback, !fallback.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return fallback.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        if let favorite = favorites.first(where: { $0.id == SavedPlace(name: "", latitude: coordinate.latitude, longitude: coordinate.longitude).id }),
           !Self.isGenericFavoriteName(favorite.name) {
            return favorite.name
        }
        if let recent = recents.first(where: {
            abs($0.latitude - coordinate.latitude) < 0.00015 && abs($0.longitude - coordinate.longitude) < 0.00015
        }), !Self.isGenericFavoriteName(recent.name) {
            return recent.name
        }
        return Self.coordinateLabel(coordinate)
    }

    private static func coordinateLabel(_ coordinate: CLLocationCoordinate2D) -> String {
        String(format: "%.5f, %.5f", coordinate.latitude, coordinate.longitude)
    }

    private static func isGenericFavoriteName(_ name: String) -> Bool {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty || trimmed == "Favorite" { return true }
        // Coordinate-looking labels from older teleports.
        let parts = trimmed.split(separator: ",")
        if parts.count == 2,
           Double(parts[0].trimmingCharacters(in: .whitespaces)) != nil,
           Double(parts[1].trimmingCharacters(in: .whitespaces)) != nil {
            return true
        }
        return false
    }

    private func apply(_ coordinate: CLLocationCoordinate2D, pairing: PairingStore, markRecent: Bool) {
        if status == .idle || status.isDropped {
            status = .connecting
        }
        isBusy = true
        let result = LocationEngine.set(
            latitude: coordinate.latitude,
            longitude: coordinate.longitude,
            pairingPath: pairing.pairingPath,
            deviceIP: TunnelConfig.targetIP
        )
        isBusy = false
        switch result {
        case .success:
            simulated = coordinate
            pin = coordinate
            status = .active
            lastError = nil
            reconnectTask?.cancel()
            reconnectTask = nil
            beginBackground()
            locationKeeper.useHighAccuracy(false)
            locationKeeper.start()
            startResend(pairing: pairing)
            startHealth(pairing: pairing)
            if markRecent {
                pushRecent(coordinate)
                saveActiveSimulation(coordinate)
            }
        case .failure(let error):
            if simulated != nil {
                // Keep the target; only Stop ends a simulation.
                simulated = coordinate
                startReconnect(pairing: pairing)
            } else {
                lastError = error.localizedDescription
                status = .idle
            }
        }
    }

    private func saveActiveSimulation(_ coordinate: CLLocationCoordinate2D) {
        let place = SavedPlace(name: "", latitude: coordinate.latitude, longitude: coordinate.longitude)
        SavedPlace.save([place], key: activeSimulationKey)
    }

    /// Off the main actor: reconnecting can take seconds and must not freeze the UI.
    private func send(_ coordinate: CLLocationCoordinate2D, pairing: PairingStore) async -> Bool {
        let latitude = coordinate.latitude
        let longitude = coordinate.longitude
        let path = pairing.pairingPath
        let ip = TunnelConfig.targetIP
        let result = await Task.detached(priority: .userInitiated) {
            LocationEngine.set(latitude: latitude, longitude: longitude, pairingPath: path, deviceIP: ip)
        }.value
        // Stop may have run while this was in flight; don't leave it re-enabled.
        guard simulated != nil else {
            _ = await Task.detached(priority: .userInitiated) {
                LocationEngine.clear(pairingPath: path, deviceIP: ip)
            }.value
            return false
        }
        if case .success = result { return true }
        return false
    }

    /// Retries until it works or Stop is pressed; a lost tunnel never ends the simulation.
    private func startReconnect(pairing: PairingStore) {
        guard reconnectTask == nil, simulated != nil else { return }
        status = .reconnecting
        beginBackground()
        reconnectTask = Task { [weak self] in
            var attempts = 0
            var delaySeconds: UInt64 = 1
            while !Task.isCancelled {
                guard let self, let target = self.simulated else { return }
                let delivered = await self.send(target, pairing: pairing)
                if Task.isCancelled { return }
                if delivered {
                    self.reconnectTask = nil
                    self.status = .active
                    self.lastError = nil
                    return
                }
                attempts += 1
                if attempts == 5 {
                    self.postDropNotification("Still reconnecting. Keep LocalDevVPN connected.")
                }
                try? await Task.sleep(nanoseconds: delaySeconds * 1_000_000_000)
                delaySeconds = min(delaySeconds * 2, 8)
            }
        }
    }

    private func tickJoystick(pairing: PairingStore) {
        guard joystickActive, status == .active, let current = simulated else { return }
        let magnitude = hypot(joystickVector.dx, joystickVector.dy)
        guard magnitude > 0.08 else { return }
        let nx = joystickVector.dx / magnitude
        let ny = -joystickVector.dy / magnitude
        let jitter = customSpeedEnabled ? 1.0 : Double.random(in: 0.9...1.1)
        let speed = activeSpeed * min(1.0, magnitude) * jitter
        let dt = 0.25
        let meters = speed * dt
        let next = offset(coordinate: current, eastMeters: nx * meters, northMeters: ny * meters)
        apply(next, pairing: pairing, markRecent: false)
    }

    private func startResend(pairing: PairingStore) {
        resendTimer?.invalidate()
        resendTimer = Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self, !self.resendInFlight, self.reconnectTask == nil,
                      let sim = self.simulated else { return }
                self.saveActiveSimulation(sim)
                self.resendInFlight = true
                let delivered = await self.send(sim, pairing: pairing)
                self.resendInFlight = false
                if !delivered {
                    self.startReconnect(pairing: pairing)
                }
            }
        }
    }

    private func stopResend() {
        resendTimer?.invalidate()
        resendTimer = nil
    }

    private func startHealth(pairing: PairingStore) {
        healthTimer?.invalidate()
        healthTimer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.isSpoofing, !LocationEngine.isSessionActive else { return }
                self.startReconnect(pairing: pairing)
            }
        }
    }

    private func stopHealth() {
        healthTimer?.invalidate()
        healthTimer = nil
    }

    private func pushRecent(_ coordinate: CLLocationCoordinate2D) {
        pushNamedRecent(
            name: Self.coordinateLabel(coordinate),
            coordinate: coordinate
        )
    }

    func pushNamedRecent(name: String, coordinate: CLLocationCoordinate2D) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let place = SavedPlace(
            name: trimmed.isEmpty ? Self.coordinateLabel(coordinate) : trimmed,
            latitude: coordinate.latitude,
            longitude: coordinate.longitude
        )
        recents.removeAll {
            abs($0.latitude - place.latitude) < 0.00015 && abs($0.longitude - place.longitude) < 0.00015
        }
        recents.insert(place, at: 0)
        if recents.count > 20 { recents = Array(recents.prefix(20)) }
        SavedPlace.save(recents, key: recentsKey)
    }

    private func beginBackground() {
        guard backgroundTask == .invalid else { return }
        backgroundTask = UIApplication.shared.beginBackgroundTask { [weak self] in
            self?.endBackground()
        }
    }

    private func endBackground() {
        guard backgroundTask != .invalid else { return }
        UIApplication.shared.endBackgroundTask(backgroundTask)
        backgroundTask = .invalid
    }

    private func postDropNotification(_ message: String) {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
        let content = UNMutableNotificationContent()
        content.title = "Locus spoof dropped"
        content.body = message
        content.sound = .default
        let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request)
    }

    private func offset(coordinate: CLLocationCoordinate2D, eastMeters: Double, northMeters: Double) -> CLLocationCoordinate2D {
        let earth = 6378137.0
        let dLat = northMeters / earth * (180 / .pi)
        let dLon = eastMeters / (earth * cos(coordinate.latitude * .pi / 180)) * (180 / .pi)
        return CLLocationCoordinate2D(latitude: coordinate.latitude + dLat, longitude: coordinate.longitude + dLon)
    }
}
