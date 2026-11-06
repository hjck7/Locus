import CoreLocation
import Foundation
import MapKit

/// One way to reach the destination, as drawn on the map and offered in the planner.
struct RouteCandidate: Identifiable {
    let id = UUID()
    var title: String
    var coordinates: [CLLocationCoordinate2D]
    /// Starts of Apple Maps maneuvers, i.e. real turns and junctions.
    var turns: [CLLocationCoordinate2D]
    let length: CLLocationDistance
    /// Thinned out for drawing; long routes would otherwise slow the map down.
    let displayCoordinates: [CLLocationCoordinate2D]

    init(title: String, coordinates: [CLLocationCoordinate2D], turns: [CLLocationCoordinate2D]) {
        self.title = title
        self.coordinates = coordinates
        self.turns = turns
        length = RoutePath(coordinates).length
        let stride = max(1, coordinates.count / 400)
        var thinned = coordinates.enumerated().filter { $0.offset % stride == 0 }.map(\.element)
        if let last = coordinates.last { thinned.append(last) }
        displayCoordinates = thinned
    }
}

/// Turns coordinates into names people recognise.
enum PlaceNamer {
    static func isCoordinateLabel(_ name: String) -> Bool {
        let parts = name.split(separator: ",")
        return parts.count == 2 && parts.allSatisfy { Double($0.trimmingCharacters(in: .whitespaces)) != nil }
    }

    static func name(for coordinate: CLLocationCoordinate2D) async -> String {
        let location = CLLocation(latitude: coordinate.latitude, longitude: coordinate.longitude)
        let placemark = try? await CLGeocoder().reverseGeocodeLocation(location).first
        return placemark?.name ?? placemark?.thoroughfare ?? placemark?.locality ?? "Ziel"
    }
}

/// A polyline addressed by the distance travelled along it.
struct RoutePath {
    let coordinates: [CLLocationCoordinate2D]
    private let cumulative: [CLLocationDistance]

    init(_ coordinates: [CLLocationCoordinate2D]) {
        self.coordinates = coordinates
        var total: CLLocationDistance = 0
        var distances: [CLLocationDistance] = [0]
        distances.reserveCapacity(coordinates.count)
        for (a, b) in zip(coordinates, coordinates.dropFirst()) {
            total += Self.meters(from: a, to: b)
            distances.append(total)
        }
        cumulative = distances
    }

    var length: CLLocationDistance { cumulative.last ?? 0 }

    func coordinate(at distance: CLLocationDistance) -> CLLocationCoordinate2D {
        guard coordinates.count > 1 else { return coordinates.first ?? CLLocationCoordinate2D() }
        if distance <= 0 { return coordinates[0] }
        if distance >= length { return coordinates[coordinates.count - 1] }
        var low = 0
        var high = cumulative.count - 1
        while high - low > 1 {
            let middle = (low + high) / 2
            if cumulative[middle] <= distance {
                low = middle
            } else {
                high = middle
            }
        }
        let span = cumulative[high] - cumulative[low]
        let t = span > 0 ? (distance - cumulative[low]) / span : 0
        let a = coordinates[low]
        let b = coordinates[high]
        return CLLocationCoordinate2D(
            latitude: a.latitude + (b.latitude - a.latitude) * t,
            longitude: a.longitude + (b.longitude - a.longitude) * t
        )
    }

    /// Where `point` projects onto the path, and how far off the path it lies.
    func nearest(to point: CLLocationCoordinate2D) -> (along: CLLocationDistance, offset: CLLocationDistance) {
        var best: (along: CLLocationDistance, offset: CLLocationDistance) = (0, .greatestFiniteMagnitude)
        let metersPerDegree = 111_320.0
        let lonScale = cos(point.latitude * .pi / 180)
        for index in 0..<max(0, coordinates.count - 1) {
            let a = coordinates[index]
            let b = coordinates[index + 1]
            let abx = (b.longitude - a.longitude) * lonScale * metersPerDegree
            let aby = (b.latitude - a.latitude) * metersPerDegree
            let apx = (point.longitude - a.longitude) * lonScale * metersPerDegree
            let apy = (point.latitude - a.latitude) * metersPerDegree
            let squared = abx * abx + aby * aby
            let t = squared > 0 ? min(1, max(0, (apx * abx + apy * aby) / squared)) : 0
            let offset = hypot(apx - abx * t, apy - aby * t)
            if offset < best.offset {
                best = (cumulative[index] + (cumulative[index + 1] - cumulative[index]) * t, offset)
            }
        }
        return best
    }

    private static func meters(from a: CLLocationCoordinate2D, to b: CLLocationCoordinate2D) -> CLLocationDistance {
        CLLocation(latitude: a.latitude, longitude: a.longitude)
            .distance(from: CLLocation(latitude: b.latitude, longitude: b.longitude))
    }
}

enum RouteWaypointKind {
    case trafficLight
    case turn
}

struct RouteWaypoint {
    var distance: CLLocationDistance
    var kind: RouteWaypointKind
}

struct RoutePlan {
    var path: RoutePath
    var waypoints: [RouteWaypoint]
    /// Fixed speed for this trip, overriding the travel mode and custom speed.
    var speedOverride: CLLocationSpeed?
    var destinationName: String?
    var signals: [CLLocationCoordinate2D]
    var displayCoordinates: [CLLocationCoordinate2D]
}

/// One drive of a Rundfahrt, ending at `destination`.
struct CruiseLeg {
    var plan: RoutePlan
    var destination: CruiseStop
    var isDetour: Bool
}

/// A full round from the first stop back to it.
struct CruiseLap {
    var start: CruiseStop
    var legs: [CruiseLeg]
    var distance: CLLocationDistance
    var seconds: TimeInterval
    var detours: Int
}

/// What a Rundfahrt export file contains. Routes are planned again after importing.
struct CruiseFile: Codable {
    struct Stop: Codable {
        var name: String
        var latitude: Double
        var longitude: Double
        var stayMinutes: Double
    }

    var minimumMinutes: Int
    var stops: [Stop]
}

enum RouteBuilder {
    // Public servers are often overloaded, so all are asked and the first answer wins.
    private static let signalEndpoints = [
        "https://overpass.openstreetmap.fr/api/interpreter",
        "https://overpass-api.de/api/interpreter",
        "https://overpass.kumi.systems/api/interpreter",
        "https://overpass.private.coffee/api/interpreter",
    ]

    static func routes(
        through stops: [CLLocationCoordinate2D],
        mode: TravelMode
    ) async throws -> [RouteCandidate] {
        guard stops.count >= 2 else { return [] }
        var legs: [[RouteCandidate]] = []
        for (from, to) in zip(stops, stops.dropFirst()) {
            let routes = try await calculate(from: from, to: to, mode: mode, alternates: true)
            legs.append(routes.prefix(3).map(candidate(from:)))
        }
        if legs.count == 1 { return legs[0] }

        // Multi-stop trips vary the leg with the most choices.
        let variable = legs.indices.max { legs[$0].count < legs[$1].count } ?? 0
        return legs[variable].indices.map { option in
            var coordinates: [CLLocationCoordinate2D] = []
            var turns: [CLLocationCoordinate2D] = []
            for index in legs.indices {
                let leg = legs[index][index == variable ? option : 0]
                coordinates += leg.coordinates
                turns += leg.turns
            }
            return RouteCandidate(title: option == 0 ? "Beste Route" : "Alternative \(option)", coordinates: coordinates, turns: turns)
        }
    }

    private static var noRouteError: NSError {
        NSError(domain: "Locus", code: 1, userInfo: [NSLocalizedDescriptionKey: "Keine Route gefunden."])
    }

    private static func calculate(
        from start: CLLocationCoordinate2D,
        to end: CLLocationCoordinate2D,
        mode: TravelMode,
        alternates: Bool
    ) async throws -> [MKRoute] {
        let request = MKDirections.Request()
        request.source = MKMapItem(placemark: MKPlacemark(coordinate: start))
        request.destination = MKMapItem(placemark: MKPlacemark(coordinate: end))
        request.transportType = mode.mkTransportType
        request.requestsAlternateRoutes = alternates
        let response = try await MKDirections(request: request).calculate()
        guard !response.routes.isEmpty else { throw noRouteError }
        return response.routes
    }

    private static func candidate(from route: MKRoute) -> RouteCandidate {
        RouteCandidate(
            title: route.name.isEmpty ? "Route" : route.name,
            coordinates: coordinates(of: route.polyline),
            turns: route.steps.dropFirst()
                .filter { !isRoundabout($0) }
                .compactMap { coordinates(of: $0.polyline).first }
        )
    }

    /// Traffic in a roundabout keeps flowing, so these maneuvers are not stop points.
    private static func isRoundabout(_ step: MKRoute.Step) -> Bool {
        let text = step.instructions.lowercased()
        return ["kreisverkehr", "ausfahrt", "roundabout", "rotary", "exit"].contains { text.contains($0) }
    }

    private static func coordinates(of polyline: MKPolyline) -> [CLLocationCoordinate2D] {
        var coords = [CLLocationCoordinate2D](repeating: .init(), count: polyline.pointCount)
        polyline.getCoordinates(&coords, range: NSRange(location: 0, length: polyline.pointCount))
        return coords
    }

    /// Traffic lights and stop signs near the route from OpenStreetMap, or nil when
    /// no server answered, in which case plans fall back to the route's turns.
    static func signals(
        along coordinates: [CLLocationCoordinate2D],
        mode: TravelMode
    ) async -> [CLLocationCoordinate2D]? {
        guard coordinates.count > 1 else { return [] }
        let path = RoutePath(coordinates)
        let spacing = max(80, path.length / 150)
        let line = stride(from: 0, through: path.length, by: spacing)
            .map { path.coordinate(at: $0) }
            .map { String(format: "%.5f,%.5f", $0.latitude, $0.longitude) }
            .joined(separator: ",")
        let types = mode == .walk || mode == .run ? "traffic_signals|crossing" : "traffic_signals|stop"
        let query = "[out:json][timeout:15];node[\"highway\"~\"^(\(types))$\"](around:18,\(line));out skel;"
        let found = await fetchSignals(query: query)
        return found?.filter { path.nearest(to: $0).offset <= 25 }
    }

    private static func fetchSignals(from endpoint: String, body: String) async -> [CLLocationCoordinate2D]? {
        guard let url = URL(string: endpoint) else { return nil }
        var request = URLRequest(url: url, timeoutInterval: 20)
        request.httpMethod = "POST"
        request.setValue("LocationLarper/1.4 (iOS)", forHTTPHeaderField: "User-Agent")
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = Data(body.utf8)
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200,
              let decoded = try? JSONDecoder().decode(OverpassResponse.self, from: data) else { return nil }
        return decoded.elements.map { CLLocationCoordinate2D(latitude: $0.lat, longitude: $0.lon) }
    }

    private static let maxLapLegs = 40

    /// Plans legs until the lap lasts at least `minimumMinutes`, then returns to the
    /// first stop. Base routes repeat on purpose; detours and alternatives add variety.
    static func buildLap(
        stops: [CruiseStop],
        mode: TravelMode,
        speed: CLLocationSpeed,
        minimumMinutes: Int
    ) async throws -> CruiseLap {
        guard stops.count >= 2 else { throw noRouteError }
        var known: [String: [RouteCandidate]] = [:]
        var picks: [(candidate: RouteCandidate, stop: CruiseStop, detour: Bool)] = []
        var seconds = stops[0].stayMinutes * 60
        var distance: CLLocationDistance = 0
        var detours = 0
        var current = 0
        var previous = 0

        while picks.count < maxLapLegs {
            let done = seconds >= Double(minimumMinutes) * 60
            if done && current == 0 { break }
            let next = done ? 0 : nextCruiseStop(current: current, previous: previous, count: stops.count)
            let from = stops[current].coordinate
            let to = stops[next].coordinate
            let key = "\(current)-\(next)"
            if known[key] == nil {
                known[key] = try await routes(through: [from, to], mode: mode)
            }
            guard let options = known[key], let base = options.first else { throw noRouteError }

            var chosen = base
            var detour = false
            let roll = Double.random(in: 0..<1)
            if roll < 0.35, let side = try? await routes(through: [from, detourPoint(from: from, to: to), to], mode: mode).first {
                chosen = side
                detour = true
                detours += 1
            } else if roll < 0.6, options.count > 1 {
                chosen = options[Int.random(in: 1..<options.count)]
            }
            picks.append((chosen, stops[next], detour))
            distance += chosen.length
            seconds += chosen.length / max(speed, 0.1) + stops[next].stayMinutes * 60
            previous = current
            current = next
        }

        // One request for the whole area keeps a long lap from hammering the servers.
        let lights = await signals(inBoundsOf: picks.flatMap(\.candidate.displayCoordinates), mode: mode) ?? []
        let legs = picks.map { pick in
            CruiseLeg(
                plan: plan(pick.candidate, signals: lights, destinationName: pick.stop.name),
                destination: pick.stop,
                isDetour: pick.detour
            )
        }
        return CruiseLap(start: stops[0], legs: legs, distance: distance, seconds: seconds, detours: detours)
    }

    private static func nextCruiseStop(current: Int, previous: Int, count: Int) -> Int {
        let roll = Double.random(in: 0..<1)
        if roll < 0.6 { return (current + 1) % count }
        if roll < 0.8, previous != current { return previous }
        let others = (0..<count).filter { $0 != current }
        return others.randomElement() ?? (current + 1) % count
    }

    /// A point beside the direct line, so the route turns off and comes back.
    private static func detourPoint(from: CLLocationCoordinate2D, to: CLLocationCoordinate2D) -> CLLocationCoordinate2D {
        let metersPerDegree = 111_320.0
        let lonScale = cos(from.latitude * .pi / 180)
        let east = (to.longitude - from.longitude) * lonScale * metersPerDegree
        let north = (to.latitude - from.latitude) * metersPerDegree
        let length = max(hypot(east, north), 1)
        let side = Bool.random() ? 1.0 : -1.0
        let offset = min(max(length * 0.3, 200), 900) * side
        let along = Double.random(in: 0.3...0.7)
        return CLLocationCoordinate2D(
            latitude: from.latitude + (to.latitude - from.latitude) * along + (east / length * offset) / metersPerDegree,
            longitude: from.longitude + (to.longitude - from.longitude) * along - (north / length * offset) / (metersPerDegree * lonScale)
        )
    }

    private static func signals(
        inBoundsOf coordinates: [CLLocationCoordinate2D],
        mode: TravelMode
    ) async -> [CLLocationCoordinate2D]? {
        guard let south = coordinates.map(\.latitude).min(),
              let north = coordinates.map(\.latitude).max(),
              let west = coordinates.map(\.longitude).min(),
              let east = coordinates.map(\.longitude).max() else { return [] }
        let box = String(format: "%.4f,%.4f,%.4f,%.4f", south, west, north, east)
        let types = mode == .walk || mode == .run ? "traffic_signals|crossing" : "traffic_signals|stop"
        return await fetchSignals(query: "[out:json][timeout:15];node[\"highway\"~\"^(\(types))$\"](\(box));out skel;")
    }

    private static func fetchSignals(query: String) async -> [CLLocationCoordinate2D]? {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        guard let encoded = query.addingPercentEncoding(withAllowedCharacters: allowed) else { return nil }
        return await withTaskGroup(of: [CLLocationCoordinate2D]?.self) { group -> [CLLocationCoordinate2D]? in
            for endpoint in signalEndpoints {
                group.addTask { await fetchSignals(from: endpoint, body: "data=\(encoded)") }
            }
            for await result in group {
                if let result {
                    group.cancelAll()
                    return result
                }
            }
            return nil
        }
    }

    static func plan(
        _ candidate: RouteCandidate,
        signals: [CLLocationCoordinate2D],
        speedOverride: CLLocationSpeed? = nil,
        destinationName: String? = nil
    ) -> RoutePlan {
        let path = RoutePath(candidate.coordinates)
        let onRoute = signals.compactMap { signal -> (coordinate: CLLocationCoordinate2D, along: CLLocationDistance)? in
            let match = path.nearest(to: signal)
            return match.offset <= 25 ? (signal, match.along) : nil
        }
        let lights = onRoute.map { RouteWaypoint(distance: $0.along, kind: .trafficLight) }
        let turns = candidate.turns.map { RouteWaypoint(distance: path.nearest(to: $0).along, kind: .turn) }
        // Lights win over a turn at the same junction.
        var waypoints: [RouteWaypoint] = []
        for waypoint in (lights + turns).sorted(by: { $0.distance < $1.distance }) {
            guard waypoint.distance > 20, waypoint.distance < path.length - 20 else { continue }
            if let last = waypoints.last, waypoint.distance - last.distance < 25 {
                if waypoint.kind == .trafficLight {
                    waypoints[waypoints.count - 1] = waypoint
                }
                continue
            }
            waypoints.append(waypoint)
        }
        return RoutePlan(
            path: path,
            waypoints: waypoints,
            speedOverride: speedOverride,
            destinationName: destinationName,
            signals: onRoute.map(\.coordinate),
            displayCoordinates: candidate.displayCoordinates
        )
    }

    static func sample(coordinates: [CLLocationCoordinate2D], every meters: CLLocationDistance) -> [CLLocationCoordinate2D] {
        guard coordinates.count > 1 else { return coordinates }
        var sampled = [coordinates[0]]
        for (a, b) in zip(coordinates, coordinates.dropFirst()) {
            let dist = CLLocation(latitude: a.latitude, longitude: a.longitude)
                .distance(from: CLLocation(latitude: b.latitude, longitude: b.longitude))
            let steps = max(1, Int(ceil(dist / meters)))
            for i in 1...steps {
                let t = Double(i) / Double(steps)
                sampled.append(CLLocationCoordinate2D(
                    latitude: a.latitude + (b.latitude - a.latitude) * t,
                    longitude: a.longitude + (b.longitude - a.longitude) * t
                ))
            }
        }
        return sampled
    }
}

private struct OverpassResponse: Decodable {
    struct Element: Decodable {
        let lat: Double
        let lon: Double
    }

    let elements: [Element]
}

enum GPXCodec {
    static func parse(_ url: URL) throws -> [CLLocationCoordinate2D] {
        let accessing = url.startAccessingSecurityScopedResource()
        defer { if accessing { url.stopAccessingSecurityScopedResource() } }
        let data = try Data(contentsOf: url)
        let text = String(decoding: data, as: UTF8.self)
        var coords: [CLLocationCoordinate2D] = []
        let pattern = #"lat="([^"]+)"[^>]*lon="([^"]+)""#
        let regex = try NSRegularExpression(pattern: pattern)
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        regex.enumerateMatches(in: text, range: range) { match, _, _ in
            guard let match,
                  let latR = Range(match.range(at: 1), in: text),
                  let lonR = Range(match.range(at: 2), in: text),
                  let lat = Double(text[latR]),
                  let lon = Double(text[lonR]) else { return }
            coords.append(CLLocationCoordinate2D(latitude: lat, longitude: lon))
        }
        // Also support lon before lat
        if coords.isEmpty {
            let alt = #"lon="([^"]+)"[^>]*lat="([^"]+)""#
            let altRegex = try NSRegularExpression(pattern: alt)
            altRegex.enumerateMatches(in: text, range: range) { match, _, _ in
                guard let match,
                      let lonR = Range(match.range(at: 1), in: text),
                      let latR = Range(match.range(at: 2), in: text),
                      let lon = Double(text[lonR]),
                      let lat = Double(text[latR]) else { return }
                coords.append(CLLocationCoordinate2D(latitude: lat, longitude: lon))
            }
        }
        guard !coords.isEmpty else {
            throw NSError(domain: "Locus", code: 2, userInfo: [NSLocalizedDescriptionKey: "No track points found in GPX"])
        }
        return coords
    }

    static func export(_ coordinates: [CLLocationCoordinate2D], name: String = "Location Larper Route") -> String {
        var body = """
        <?xml version="1.0" encoding="UTF-8"?>
        <gpx version="1.1" creator="Location Larper" xmlns="http://www.topografix.com/GPX/1/1">
          <trk>
            <name>\(name)</name>
            <trkseg>

        """
        for c in coordinates {
            body += String(format: "      <trkpt lat=\"%.6f\" lon=\"%.6f\"></trkpt>\n", c.latitude, c.longitude)
        }
        body += """
            </trkseg>
          </trk>
        </gpx>
        """
        return body
    }
}
