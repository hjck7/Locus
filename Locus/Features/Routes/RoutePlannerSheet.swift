import CoreLocation
import MapKit
import SwiftUI

struct RouteStopDraft: Identifiable {
    let id = UUID()
    var name: String
    var coordinate: CLLocationCoordinate2D
}

enum RouteSlot: String, CaseIterable, Identifiable {
    case start, via, destination

    var id: String { rawValue }

    var title: String {
        switch self {
        case .start: return "Start"
        case .via: return "Zwischenstopp"
        case .destination: return "Ziel"
        }
    }
}

enum PlannerMode: String, CaseIterable, Identifiable {
    case route, cruise

    var id: String { rawValue }

    var title: String {
        switch self {
        case .route: return "Route"
        case .cruise: return "Rundfahrt"
        }
    }
}

enum SignalState: Equatable {
    case idle
    case loading
    case found(Int)
    case unavailable
}

enum RouteFormat {
    static func distance(_ meters: CLLocationDistance) -> String {
        meters < 1000 ? "\(Int(meters)) m" : String(format: "%.1f km", meters / 1000)
    }

    static func duration(_ seconds: TimeInterval) -> String {
        let minutes = Int((seconds / 60).rounded(.up))
        if minutes < 60 { return "\(minutes) min" }
        return "\(minutes / 60) h \(minutes % 60) min"
    }
}

@MainActor
final class RoutePlannerModel: ObservableObject {
    static let maxCruiseStops = 6

    @Published var mode = PlannerMode.route
    @Published var start: RouteStopDraft?
    @Published var vias: [RouteStopDraft] = []
    @Published var destination: RouteStopDraft?
    @Published var cruiseStops: [CruiseStop] = []
    @Published private(set) var candidates: [RouteCandidate] = []
    @Published private(set) var selectedID: UUID?
    @Published private(set) var signals: [CLLocationCoordinate2D] = []
    @Published private(set) var signalState = SignalState.idle
    @Published private(set) var isRouting = false
    @Published var pickingSlot: RouteSlot?
    /// While on, every map tap adds the next point.
    @Published var tapMode = false

    private var buildTask: Task<Void, Never>?
    private var signalTask: Task<Void, Never>?

    var selected: RouteCandidate? {
        candidates.first { $0.id == selectedID } ?? candidates.first
    }

    var tapHint: String {
        if mode == .cruise {
            if cruiseStops.isEmpty { return "Tippe auf die Karte: Startpunkt setzen" }
            return "Tippe den nächsten Punkt (\(cruiseStops.count)/\(Self.maxCruiseStops))"
        }
        if start == nil { return "Tippe auf die Karte: Start setzen" }
        if destination == nil { return "Tippe auf die Karte: Ziel setzen" }
        return "Tippe weiter, um die Route zu verlängern"
    }

    func assign(_ slot: RouteSlot, name: String, coordinate: CLLocationCoordinate2D, session: SpoofSession) {
        let draft = RouteStopDraft(name: name, coordinate: coordinate)
        switch slot {
        case .start: start = draft
        case .via: vias.append(draft)
        case .destination: destination = draft
        }
        resolveName(of: draft)
        rebuild(session: session)
    }

    /// Adds a tapped point: Start, then Ziel; later taps turn the old Ziel into a stop.
    func addTap(_ coordinate: CLLocationCoordinate2D, session: SpoofSession) {
        let label = String(format: "%.5f, %.5f", coordinate.latitude, coordinate.longitude)
        if mode == .cruise {
            guard cruiseStops.count < Self.maxCruiseStops else { return }
            addCruiseStop(name: label, coordinate: coordinate)
            return
        }
        if start == nil {
            assign(.start, name: label, coordinate: coordinate, session: session)
        } else if let previous = destination {
            vias.append(previous)
            assign(.destination, name: label, coordinate: coordinate, session: session)
        } else {
            assign(.destination, name: label, coordinate: coordinate, session: session)
        }
    }

    func undoTap(session: SpoofSession) {
        if mode == .cruise {
            _ = cruiseStops.popLast()
        } else if destination != nil {
            destination = vias.popLast()
            rebuild(session: session)
        } else {
            start = nil
        }
    }

    func addCruiseStop(name: String, coordinate: CLLocationCoordinate2D) {
        guard cruiseStops.count < Self.maxCruiseStops else { return }
        let stop = CruiseStop(name: name, coordinate: coordinate, stayMinutes: 5)
        cruiseStops.append(stop)
        guard PlaceNamer.isCoordinateLabel(name) else { return }
        Task { [weak self] in
            let resolved = await PlaceNamer.name(for: coordinate)
            guard let self, let index = self.cruiseStops.firstIndex(where: { $0.id == stop.id }) else { return }
            self.cruiseStops[index].name = resolved
        }
    }

    private func resolveName(of draft: RouteStopDraft) {
        guard PlaceNamer.isCoordinateLabel(draft.name) else { return }
        Task { [weak self] in
            let resolved = await PlaceNamer.name(for: draft.coordinate)
            guard let self else { return }
            if self.start?.id == draft.id { self.start?.name = resolved }
            if self.destination?.id == draft.id { self.destination?.name = resolved }
            if let index = self.vias.firstIndex(where: { $0.id == draft.id }) {
                self.vias[index].name = resolved
            }
        }
    }

    func remove(_ slot: RouteSlot, viaIndex: Int? = nil, session: SpoofSession) {
        switch slot {
        case .start: start = nil
        case .via:
            if let viaIndex, vias.indices.contains(viaIndex) { vias.remove(at: viaIndex) }
        case .destination: destination = nil
        }
        rebuild(session: session)
    }

    func clear() {
        buildTask?.cancel()
        signalTask?.cancel()
        start = nil
        vias = []
        destination = nil
        candidates = []
        selectedID = nil
        signals = []
        signalState = .idle
        isRouting = false
    }

    /// For GPX imports and hand-drawn paths, which skip Apple Maps routing.
    func useCustomPath(_ coordinates: [CLLocationCoordinate2D], title: String, session: SpoofSession) {
        clear()
        guard coordinates.count > 1 else { return }
        let candidate = RouteCandidate(title: title, coordinates: coordinates, turns: [])
        candidates = [candidate]
        selectedID = candidate.id
        loadSignals(session: session)
    }

    func select(_ candidate: RouteCandidate, session: SpoofSession) {
        selectedID = candidate.id
        loadSignals(session: session)
    }

    func rebuild(session: SpoofSession) {
        buildTask?.cancel()
        signalTask?.cancel()
        signals = []
        signalState = .idle
        guard let destination else {
            candidates = []
            selectedID = nil
            isRouting = false
            return
        }
        guard let origin = start?.coordinate ?? session.simulated ?? session.realCoordinate else {
            isRouting = false
            session.lastError = "Dein Standort ist noch nicht bekannt. Wähle einen Startpunkt."
            return
        }
        let stops = [origin] + vias.map(\.coordinate) + [destination.coordinate]
        let mode = session.travelMode
        isRouting = true
        buildTask = Task { [weak self] in
            // Quick taps must not hit the Apple Maps rate limit.
            try? await Task.sleep(nanoseconds: 500_000_000)
            if Task.isCancelled { return }
            do {
                let found = try await RouteBuilder.routes(through: stops, mode: mode)
                guard let self, !Task.isCancelled else { return }
                self.candidates = found
                self.selectedID = found.first?.id
                self.isRouting = false
                self.loadSignals(session: session)
            } catch {
                guard let self, !Task.isCancelled else { return }
                self.candidates = []
                self.selectedID = nil
                self.isRouting = false
                session.lastError = error.localizedDescription
            }
        }
    }

    private func loadSignals(session: SpoofSession) {
        guard let candidate = selected else { return }
        let mode = session.travelMode
        signalTask?.cancel()
        signals = []
        signalState = .loading
        signalTask = Task { [weak self] in
            let found = await RouteBuilder.signals(along: candidate.coordinates, mode: mode)
            guard let self, !Task.isCancelled else { return }
            self.signals = found ?? []
            self.signalState = found.map { .found($0.count) } ?? .unavailable
        }
    }

    func startDriving(session: SpoofSession, pairing: PairingStore) {
        guard let candidate = selected else { return }
        let lights = signals
        let name = destination?.name
        Task {
            let plan = await Task.detached(priority: .userInitiated) {
                RouteBuilder.plan(candidate, signals: lights, destinationName: name)
            }.value
            session.followRoute(plan, pairing: pairing)
        }
    }
}

/// Address search that lists results directly below the field.
struct PlaceSearchField: View {
    var prompt: String
    var onPick: (String, CLLocationCoordinate2D) -> Void

    @StateObject private var search = PlaceSearchCompleter()
    @State private var query = ""

    var body: some View {
        TextField(prompt, text: $query)
            .textInputAutocapitalization(.words)
            .autocorrectionDisabled()
            .onChange(of: query) { _, value in
                search.query = value
            }
        if !query.isEmpty {
            ForEach(search.results.prefix(5), id: \.self) { item in
                Button {
                    resolve(item)
                } label: {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(item.title).foregroundStyle(.primary)
                        if !item.subtitle.isEmpty {
                            Text(item.subtitle).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
            }
        }
    }

    private func resolve(_ completion: MKLocalSearchCompletion) {
        Task {
            let request = MKLocalSearch.Request(completion: completion)
            guard let response = try? await MKLocalSearch(request: request).start(),
                  let item = response.mapItems.first else { return }
            let coordinate = item.placemark.coordinate
            await MainActor.run {
                onPick(completion.title, coordinate)
                query = ""
            }
        }
    }
}

/// Stop behaviour and update rate, shared by the planner and Settings.
struct DrivingBehaviorFields: View {
    @EnvironmentObject private var session: SpoofSession

    var body: some View {
        Picker("An Ampeln halten", selection: $session.stopFrequency) {
            ForEach(StopFrequency.allCases) { Text($0.title).tag($0) }
        }
        if session.stopFrequency != .off {
            Picker("Wartezeit", selection: $session.stopDuration) {
                ForEach(StopDuration.allCases) { Text($0.title).tag($0) }
            }
        }
        VStack(alignment: .leading, spacing: 6) {
            LabeledContent("Standort aktualisieren") {
                Text(String(format: "alle %.1f s", session.updateInterval))
                    .monospacedDigit()
            }
            Slider(value: $session.updateInterval, in: SpoofSession.updateIntervalRange, step: 0.1)
        }
    }
}

struct RoutePlannerSheet: View {
    @ObservedObject var planner: RoutePlannerModel
    var onPickOnMap: (RouteSlot) -> Void
    var onTapMode: () -> Void
    var onDraw: () -> Void
    var onImportGPX: () -> Void
    var onExportGPX: () -> Void

    @EnvironmentObject private var session: SpoofSession
    @EnvironmentObject private var pairing: PairingStore
    @Environment(\.dismiss) private var dismiss
    @State private var searchSlot: RouteSlot = .destination

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Picker("Modus", selection: $planner.mode) {
                        ForEach(PlannerMode.allCases) { Text($0.title).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    Button {
                        onTapMode()
                    } label: {
                        Label("Punkte auf der Karte antippen", systemImage: "hand.tap.fill")
                            .font(.headline)
                    }
                }

                if planner.mode == .route {
                    stopsSection
                } else {
                    cruiseSection
                }
                modeSection
                if planner.mode == .route, planner.isRouting || !planner.candidates.isEmpty {
                    routesSection
                }
                Section("Fahrverhalten") {
                    DrivingBehaviorFields()
                }
                if planner.mode == .route {
                    moreSection
                }
            }
            .navigationTitle(planner.mode == .route ? "Route planen" : "Rundfahrt planen")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Schließen") { dismiss() }
                }
            }
            .safeAreaInset(edge: .bottom) {
                startButton
            }
            .onChange(of: session.travelMode) { _, _ in
                planner.rebuild(session: session)
            }
        }
    }

    private var moreSection: some View {
        Section("Mehr") {
            Button {
                onDraw()
            } label: {
                Label("Freihand zeichnen", systemImage: "pencil.tip")
            }
            Button(action: onImportGPX) {
                Label("GPX importieren", systemImage: "square.and.arrow.down")
            }
            Button(action: onExportGPX) {
                Label("GPX exportieren", systemImage: "square.and.arrow.up")
            }
            if planner.destination != nil || !planner.candidates.isEmpty {
                Button("Route löschen", role: .destructive) {
                    planner.clear()
                }
            }
        }
    }

    private var cruiseSection: some View {
        Section {
            ForEach($planner.cruiseStops) { $stop in
                VStack(alignment: .leading, spacing: 6) {
                    Text(cruiseTitle(for: stop)).font(.caption).foregroundStyle(.secondary)
                    Text(stop.name).lineLimit(1)
                    Stepper(value: $stop.stayMinutes, in: 0...120, step: 1) {
                        Text("Bleibt \(Int(stop.stayMinutes)) min").font(.footnote)
                    }
                }
            }
            .onDelete { planner.cruiseStops.remove(atOffsets: $0) }
            if planner.cruiseStops.count < RoutePlannerModel.maxCruiseStops {
                PlaceSearchField(prompt: "Ort hinzufügen") { name, coordinate in
                    planner.addCruiseStop(name: name, coordinate: coordinate)
                }
            }
        } header: {
            Text("Punkte (\(planner.cruiseStops.count)/\(RoutePlannerModel.maxCruiseStops))")
        } footer: {
            Text("Start und bis zu 5 Punkte. Du fährst endlos zwischen ihnen hin und her, oft über dieselben Straßen, in leicht wechselnder Reihenfolge. Wischen löscht einen Punkt.")
        }
    }

    private func cruiseTitle(for stop: CruiseStop) -> String {
        let index = planner.cruiseStops.firstIndex { $0.id == stop.id } ?? 0
        return index == 0 ? "Start" : "Punkt \(index)"
    }

    private var stopsSection: some View {
        Section {
            stopRow(
                slot: .start,
                title: "Start",
                name: planner.start?.name ?? "Mein aktueller Standort",
                color: LocusTheme.statusGood,
                canRemove: planner.start != nil
            ) {
                planner.remove(.start, session: session)
            }
            ForEach(Array(planner.vias.enumerated()), id: \.element.id) { index, via in
                stopRow(
                    slot: .via,
                    title: "Zwischenstopp \(index + 1)",
                    name: via.name,
                    color: LocusTheme.accentSecondary,
                    canRemove: true
                ) {
                    planner.remove(.via, viaIndex: index, session: session)
                }
            }
            stopRow(
                slot: .destination,
                title: "Ziel",
                name: planner.destination?.name ?? "Noch nicht gewählt",
                color: LocusTheme.danger,
                canRemove: planner.destination != nil
            ) {
                planner.remove(.destination, session: session)
            }

            Picker("Adresse eintragen als", selection: $searchSlot) {
                ForEach(RouteSlot.allCases) { Text($0.title).tag($0) }
            }
            PlaceSearchField(prompt: "Adresse oder Ort suchen") { name, coordinate in
                planner.assign(searchSlot, name: name, coordinate: coordinate, session: session)
            }
        } header: {
            Text("Wohin soll es gehen?")
        }
    }

    private func stopRow(
        slot: RouteSlot,
        title: String,
        name: String,
        color: Color,
        canRemove: Bool,
        onRemove: @escaping () -> Void
    ) -> some View {
        HStack(spacing: 12) {
            Circle().fill(color).frame(width: 12, height: 12)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.caption).foregroundStyle(.secondary)
                Text(name).lineLimit(1)
            }
            Spacer(minLength: 8)
            Button {
                onPickOnMap(slot)
            } label: {
                Image(systemName: "map")
            }
            .buttonStyle(.borderless)
            .accessibilityLabel("\(title) auf der Karte wählen")
            if canRemove {
                Button(action: onRemove) {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                }
                .buttonStyle(.borderless)
                .accessibilityLabel("\(title) entfernen")
            }
        }
    }

    private var modeSection: some View {
        Section("Wie bewegst du dich?") {
            Picker("Fortbewegung", selection: $session.travelMode) {
                ForEach(TravelMode.allCases) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented)
            Toggle("Eigenes Tempo", isOn: $session.customSpeedEnabled)
            if session.customSpeedEnabled {
                VStack(alignment: .leading, spacing: 6) {
                    LabeledContent("Tempo") {
                        Text(String(format: "%.0f km/h", session.customSpeedKmh)).monospacedDigit()
                    }
                    Slider(value: $session.customSpeedKmh, in: SpoofSession.customSpeedRange, step: 1)
                }
            }
        }
    }

    private var routesSection: some View {
        Section("Route auswählen") {
            if planner.isRouting {
                HStack(spacing: 10) {
                    ProgressView()
                    Text("Route wird berechnet…").foregroundStyle(.secondary)
                }
            }
            ForEach(Array(planner.candidates.enumerated()), id: \.element.id) { index, candidate in
                Button {
                    planner.select(candidate, session: session)
                } label: {
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(index == 0 ? "Empfohlen: \(candidate.title)" : candidate.title)
                                .foregroundStyle(.primary)
                                .lineLimit(1)
                            Text("\(RouteFormat.distance(candidate.length)) • ca. \(RouteFormat.duration(candidate.length / session.routeSpeed))")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer(minLength: 8)
                        if candidate.id == planner.selected?.id {
                            Image(systemName: "checkmark.circle.fill").foregroundStyle(LocusTheme.accent)
                        }
                    }
                }
            }
            signalRow
        }
    }

    @ViewBuilder
    private var signalRow: some View {
        switch planner.signalState {
        case .idle:
            EmptyView()
        case .loading:
            Label("Suche Ampeln auf der Route…", systemImage: "hourglass")
                .font(.footnote).foregroundStyle(.secondary)
        case .found(let count):
            Label("\(count) Ampeln & Stoppstellen gefunden", systemImage: "checkmark.circle")
                .font(.footnote).foregroundStyle(.secondary)
        case .unavailable:
            Label("Ampel-Server nicht erreichbar, halte an Abbiegungen", systemImage: "exclamationmark.triangle")
                .font(.footnote).foregroundStyle(.secondary)
        }
    }

    private var canStart: Bool {
        planner.mode == .route ? planner.selected != nil : planner.cruiseStops.count >= 2
    }

    private var startButton: some View {
        Button {
            if planner.mode == .route {
                planner.startDriving(session: session, pairing: pairing)
            } else {
                session.startCruise(planner.cruiseStops, pairing: pairing)
            }
            dismiss()
        } label: {
            Label(planner.mode == .route ? "Route starten" : "Rundfahrt starten", systemImage: "play.fill")
                .font(.headline)
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 14)
                .background(
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .fill(canStart ? LocusTheme.accent : Color.gray)
                )
        }
        .buttonStyle(.plain)
        .disabled(!canStart)
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(.ultraThinMaterial)
    }
}
