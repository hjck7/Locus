import SwiftUI
import NetworkExtension

struct RootView: View {
    @EnvironmentObject private var session: SpoofSession
    @EnvironmentObject private var pairing: PairingStore
    @Environment(\.scenePhase) private var scenePhase
    @State private var showSettings = false
    @State private var showPlaces = false

    var body: some View {
        // Bottom chrome is a sibling overlay aligned to the bottom — no full-screen
        // Spacer layer that can steal / pass map taps through the tray.
        ZStack(alignment: .bottom) {
            MapHomeView()

            BottomControlsView(
                showSettings: $showSettings,
                showPlaces: $showPlaces
            )
            .padding(.horizontal, 16)
            .padding(.bottom, 8)
        }
        .onAppear {
            session.resumeIfNeeded(pairing: pairing)
        }
        .onChange(of: scenePhase) { _, phase in
            session.handleScenePhase(phase, pairing: pairing)
        }
        .onReceive(NotificationCenter.default.publisher(for: .NEVPNStatusDidChange)) { _ in
            session.reconnectNow(pairing: pairing)
        }
        .sheet(isPresented: $showSettings) {
            SettingsView()
        }
        .sheet(isPresented: $showPlaces) {
            PlacesView()
        }
        .alert("Location Larper", isPresented: Binding(
            get: { session.lastError != nil },
            set: { if !$0 { session.lastError = nil } }
        )) {
            Button("OK", role: .cancel) { session.lastError = nil }
        } message: {
            Text(session.lastError ?? "")
        }
    }
}

struct StatusBarView: View {
    @EnvironmentObject private var session: SpoofSession
    @Environment(\.scenePhase) private var scenePhase

    @State private var tunnelConnected = LocalDevVPN.isConnected

    private enum Display {
        case notSpoofing
        case connectVPN
        case status(String)
    }

    private var display: Display {
        switch session.status {
        case .idle:
            return tunnelConnected ? .notSpoofing : .connectVPN
        case .connecting:
            return .status("Wird gestartet…")
        case .active:
            return .status("Standort simuliert")
        case .reconnecting:
            return .status("Verbindet neu…")
        case .dropped(let reason):
            return .status(reason.isEmpty ? "Unterbrochen" : "Unterbrochen: \(reason)")
        }
    }

    private var color: Color {
        switch display {
        case .notSpoofing:
            return Color.primary.opacity(0.55)
        case .connectVPN:
            return LocusTheme.statusWarn
        case .status:
            switch session.status {
            case .active: return LocusTheme.statusGood
            case .connecting, .reconnecting: return LocusTheme.statusWarn
            case .dropped: return LocusTheme.statusBad
            case .idle: return Color.primary.opacity(0.55)
            }
        }
    }

    private var title: String {
        switch display {
        case .notSpoofing: return "Echter Standort"
        case .connectVPN: return "LocalDevVPN verbinden"
        case .status(let text): return text
        }
    }

    var body: some View {
        Group {
            if case .connectVPN = display {
                Button(action: LocalDevVPN.openOrInstall) {
                    statusContent
                }
                .buttonStyle(.plain)
            } else {
                statusContent
            }
        }
        .onAppear { refreshTunnel() }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { refreshTunnel() }
        }
        .onChange(of: session.status) { _, _ in
            refreshTunnel()
        }
        .onReceive(NotificationCenter.default.publisher(for: .NEVPNStatusDidChange)) { _ in
            // LocalDevVPN connection changes show up here even though we don’t own the VPN.
            refreshTunnel()
        }
        .task(id: scenePhase) {
            guard scenePhase == .active else { return }
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 2_000_000_000)
                refreshTunnel()
            }
        }
    }

    private var statusContent: some View {
        HStack(spacing: 10) {
            Circle()
                .fill(color)
                .frame(width: 8, height: 8)
                .shadow(color: color.opacity(0.7), radius: 4)

            Text(title)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.primary)

            Spacer(minLength: 8)

            if case .connectVPN = display {
                Image(systemName: "lock.shield.fill")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(LocusTheme.accent)
            } else if case .active = session.status, let sim = session.simulated {
                Text(String(format: "%.4f, %.4f", sim.latitude, sim.longitude))
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .locusGlass(.clear, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .contentShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
    }

    private func refreshTunnel() {
        tunnelConnected = LocalDevVPN.isConnected
    }
}

struct BottomControlsView: View {
    @EnvironmentObject private var session: SpoofSession
    @EnvironmentObject private var pairing: PairingStore
    @Binding var showSettings: Bool
    @Binding var showPlaces: Bool

    private let trayShape = RoundedRectangle(cornerRadius: 28, style: .continuous)

    var body: some View {
        VStack(spacing: 10) {
            if session.joystickActive {
                JoystickPad { vector in
                    session.updateJoystick(vector: vector)
                }
                .frame(width: 148, height: 148)
                .frame(maxWidth: .infinity, alignment: .trailing)
            }

            if let progress = session.routeProgress {
                routeStatus(progress)
            } else if let hint {
                Text(hint)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            HStack(spacing: 6) {
                ForEach(TravelMode.allCases) { mode in
                    let selected = session.travelMode == mode
                    Button {
                        session.travelMode = mode
                    } label: {
                        Image(systemName: mode.icon)
                            .font(.footnote.weight(.semibold))
                            .foregroundStyle(selected ? .white : .secondary)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 8)
                            .background(Capsule().fill(selected ? LocusTheme.accent : Color.clear))
                            .contentShape(Capsule())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(mode.title)
                }
            }

            if !session.shortcuts.isEmpty || canAddShortcut {
                shortcutRow
            }

            HStack(spacing: 8) {
                if showsTeleport {
                    primaryButton(session.canRestore ? "Hierhin" : "Hierhin teleportieren", color: LocusTheme.accent, foreground: .white) {
                        if let pin = session.pin {
                            session.teleport(to: pin, pairing: pairing)
                        }
                    }
                    .disabled(session.isBusy)
                }
                if session.canRestore {
                    primaryButton("Echten Standort zurück", color: LocusTheme.danger, foreground: .white) {
                        session.stop(pairing: pairing)
                    }
                }
            }

            HStack(spacing: 4) {
                tile("Route", "point.topleft.down.to.point.bottomright.curvepath") {
                    session.showRoutePlanner = true
                }
                tile("Zuhause", "house.fill") {
                    session.goHome(pairing: pairing)
                }
                tile("Joystick", "dot.circle.and.hand.point.up.left.fill", active: session.joystickActive) {
                    if session.joystickActive {
                        session.stopJoystick()
                    } else {
                        session.startJoystick(pairing: pairing)
                    }
                }
                tile("Orte", "star.fill") { showPlaces = true }
                tile("Optionen", "gearshape.fill") { showSettings = true }
            }
        }
        .padding(12)
        .locusGlass(.regular, in: trayShape)
        // Whole tray absorbs taps so near-misses don't fall through to the map.
        .contentShape(trayShape)
    }

    private var hint: String? {
        if session.isPlanningRoute { return "Route wird berechnet…" }
        if session.canRestore { return nil }
        return session.pin == nil ? "Tippe auf die Karte, um einen Ort zu wählen." : nil
    }

    private var showsTeleport: Bool {
        guard let pin = session.pin else { return false }
        guard let simulated = session.simulated else { return true }
        return abs(pin.latitude - simulated.latitude) > 0.00001 || abs(pin.longitude - simulated.longitude) > 0.00001
    }

    private var canAddShortcut: Bool {
        session.pin != nil && session.shortcuts.count < SpoofSession.maxShortcuts
    }

    private var shortcutRow: some View {
        HStack(spacing: 6) {
            ForEach(session.shortcuts) { place in
                Button {
                    session.drive(to: place, pairing: pairing)
                } label: {
                    Label(place.name, systemImage: "car.fill")
                        .font(.caption.weight(.semibold))
                        .lineLimit(1)
                        .foregroundStyle(.primary)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 9)
                        .padding(.horizontal, 6)
                        .background(Capsule().fill(Color.primary.opacity(0.08)))
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .disabled(session.isBusy || session.isPlanningRoute)
                .accessibilityLabel("Mit 20 km/h zu \(place.name) fahren")
            }
            if canAddShortcut, let pin = session.pin {
                Button {
                    session.addShortcut(name: session.suggestedFavoriteName(for: pin), coordinate: pin)
                } label: {
                    Label("Shortcut", systemImage: "plus")
                        .font(.caption.weight(.semibold))
                        .lineLimit(1)
                        .foregroundStyle(.primary)
                        .padding(.vertical, 9)
                        .padding(.horizontal, 10)
                        .background(Capsule().stroke(Color.primary.opacity(0.2)))
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Aktuellen Pin als Shortcut speichern")
            }
        }
    }

    private func routeStatus(_ progress: RouteProgress) -> some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 4) {
                Text(progress.title)
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(1)
                Text("Noch \(RouteFormat.distance(progress.remaining)) • ca. \(RouteFormat.duration(progress.remainingTime)) • \(Int(progress.speedKmh)) km/h")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                ProgressView(value: progress.fraction)
                    .tint(LocusTheme.accent)
            }
            Button {
                session.routePaused.toggle()
            } label: {
                Image(systemName: session.routePaused ? "play.fill" : "pause.fill")
                    .frame(width: 40, height: 40)
                    .background(Circle().fill(Color.primary.opacity(0.08)))
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(session.routePaused ? "Route fortsetzen" : "Route pausieren")
            Button {
                session.cancelRoute()
            } label: {
                Image(systemName: "xmark")
                    .frame(width: 40, height: 40)
                    .background(Circle().fill(Color.primary.opacity(0.08)))
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Route beenden und hier bleiben")
        }
    }

    private func primaryButton(_ title: String, color: Color, foreground: Color, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.subheadline.weight(.bold))
                .lineLimit(1)
                .minimumScaleFactor(0.8)
                .foregroundStyle(foreground)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 13)
                .background(Capsule().fill(color))
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
    }

    private func tile(_ title: String, _ systemName: String, active: Bool = false, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 3) {
                Image(systemName: systemName).font(.body.weight(.semibold))
                Text(title).font(.caption2).lineLimit(1).minimumScaleFactor(0.8)
            }
            .foregroundStyle(active ? LocusTheme.accentSecondary : .primary)
            .frame(maxWidth: .infinity, minHeight: 44)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

struct IconButton: View {
    let systemName: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.body.weight(.semibold))
                .frame(width: 44, height: 44)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .locusGlass(.interactive, in: Circle())
        .foregroundStyle(.primary)
    }
}
