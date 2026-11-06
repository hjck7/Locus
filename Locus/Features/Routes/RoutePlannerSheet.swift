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
    @Published var start: RouteStopDraft?
    @Published var vias: [RouteStopDraft] = []
    @Published var destination: RouteStopDraft?
    @Published private(set) var candidates: [RouteCandidate] = []
    @Published private(set) var selectedID: UUID?
    @Published private(set) var signals: [CLLocationCoordinate2D] = []
    @Published private(set) var isRouting = false
    @Published var pickingSlot: RouteSlot?

    private var buildTask: Task<Void, Never>?

    var selected: RouteCandidate? {
        candidates.first { $0.id == selectedID } ?? candidates.first
    }

    func assign(_ slot: RouteSlot, name: String, coordinate: CLLocationCoordinate2D, session: SpoofSession) {
        let draft = RouteStopDraft(name: name, coordinate: coordinate)
        switch slot {
        case .start: start = draft
        case .via: vias.append(draft)
        case .destination: destination = draft
        }
        rebuild(session: session)
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
        start = nil
        vias = []
        destination = nil
        candidates = []
        selectedID = nil
        signals = []
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
        signals = []
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
        let id = candidate.id
        Task { [weak self] in
            let found = await RouteBuilder.signals(along: candidate.coordinates, mode: mode)
            guard let self, self.selected?.id == id else { return }
            self.signals = found
        }
    }

    func startDriving(session: SpoofSession, pairing: PairingStore) {
        guard let candidate = selected else { return }
        session.followRoute(RouteBuilder.plan(candidate, signals: signals), pairing: pairing)
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
        Picker("An Ampeln & Kreuzungen halten", selection: $session.stopFrequency) {
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
                stopsSection
                modeSection
                if planner.isRouting || !planner.candidates.isEmpty {
                    routesSection
                }
                Section {
                    DrivingBehaviorFields()
                } header: {
                    Text("Fahrverhalten")
                } footer: {
                    Text("Ampeln kommen aus OpenStreetMap. Ist der Dienst nicht erreichbar, hält die Route an echten Abbiegungen.")
                }
                Section("Mehr") {
                    Button {
                        onDraw()
                    } label: {
                        Label("Route selbst auf die Karte zeichnen", systemImage: "pencil.tip")
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
            .navigationTitle("Route planen")
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
            Button {
                onPickOnMap(.via)
            } label: {
                Label("Zwischenstopp auf der Karte setzen", systemImage: "plus.circle")
            }
        } header: {
            Text("Wohin soll es gehen?")
        } footer: {
            Text("Suche eine Adresse oder tippe auf das Karten-Symbol und wähle den Punkt direkt auf der Karte.")
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
            ForEach(planner.candidates) { candidate in
                let length = RoutePath(candidate.coordinates).length
                Button {
                    planner.select(candidate, session: session)
                } label: {
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(candidate.title).foregroundStyle(.primary).lineLimit(1)
                            Text("\(RouteFormat.distance(length)) • ca. \(RouteFormat.duration(length / session.routeSpeed))")
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
            if !planner.signals.isEmpty {
                Label("\(planner.signals.count) Ampeln & Stoppstellen auf der Route", systemImage: "light.beacon.max")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var startButton: some View {
        Button {
            planner.startDriving(session: session, pairing: pairing)
            dismiss()
        } label: {
            Label("Route starten", systemImage: "play.fill")
                .font(.headline)
                .foregroundStyle(.black)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 14)
                .background(
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .fill(planner.selected == nil ? Color.gray : LocusTheme.accent)
                )
        }
        .buttonStyle(.plain)
        .disabled(planner.selected == nil)
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(.ultraThinMaterial)
    }
}
