import SwiftUI
import UniformTypeIdentifiers

struct SettingsView: View {
    @EnvironmentObject private var pairing: PairingStore
    @EnvironmentObject private var session: SpoofSession
    @Environment(\.dismiss) private var dismiss

    @State private var showImporter = false
    @State private var showPairOnDevice = false
    @State private var tunnelIP = TunnelConfig.targetIP
    @State private var localDevVPNInstalled = LocalDevVPN.isInstalled
    @State private var speedText = ""
    @State private var shortcutToRename: SavedPlace?
    @State private var shortcutName = ""
    @Environment(\.scenePhase) private var scenePhase

    private var supportsOnDevicePairing: Bool {
        if #available(iOS 27.0, *) { return true }
        return false
    }

    private var appVersion: String {
        let short = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "—"
        let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? ""
        return build.isEmpty ? short : "\(short) (\(build))"
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Label {
                        Text(pairing.hasPairingFile ? "RPPairing file installed" : "No pairing file")
                    } icon: {
                        Image(systemName: pairing.hasPairingFile ? "checkmark.seal.fill" : "exclamationmark.triangle.fill")
                            .foregroundStyle(pairing.hasPairingFile ? LocusTheme.statusGood : LocusTheme.statusWarn)
                    }

                    if supportsOnDevicePairing {
                        Button {
                            showPairOnDevice = true
                        } label: {
                            Label("Pair on this iPhone", systemImage: "iphone.gen3.radiowaves.left.and.right")
                        }
                    }

                    Button("Import RPPairing file…") { showImporter = true }
                    Button("Paste RPPairing from clipboard") {
                        do {
                            try pairing.importPairingFromClipboard()
                        } catch {
                            session.lastError = error.localizedDescription
                        }
                    }
                    if pairing.hasPairingFile {
                        Button("Remove pairing file", role: .destructive) {
                            try? pairing.removePairing()
                        }
                    }
                } header: {
                    Text("Developer pairing")
                } footer: {
                    Text(supportsOnDevicePairing
                         ? "On iOS 27, use Pair on this iPhone — no computer. Location Larper advertises a pairable host; confirm the 6-digit code under Settings › Privacy & Security › Developer Mode › Pair with Host. On older iOS, import an RPPairing file from idevice_pair (not a SideStore lockdown .mobiledevicepairing). LiveContainer: enable Fix File Picker on Location Larper, or use Paste / Share → LiveContainer → Location Larper."
                         : "Import an RPPairing file from idevice_pair (not a SideStore lockdown .mobiledevicepairing). If the file picker fails (common in LiveContainer), enable Fix File Picker on the app, share the file into LiveContainer → Location Larper, or copy the plist and use Paste.")
                }

                Section {
                    TextField("Device tunnel IP", text: $tunnelIP)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .onSubmit {
                            TunnelConfig.setTargetIP(tunnelIP)
                        }
                    LabeledContent("Status") {
                        Text(LocalDevVPN.isConnected ? "Connected" : "Not connected")
                            .foregroundStyle(LocalDevVPN.isConnected ? LocusTheme.statusGood : LocusTheme.statusWarn)
                    }
                    Button("Save tunnel IP") {
                        TunnelConfig.setTargetIP(tunnelIP)
                    }
                    Button {
                        if localDevVPNInstalled {
                            LocalDevVPN.openInstalled()
                        } else {
                            LocalDevVPN.openAppStore()
                        }
                    } label: {
                        Label(
                            localDevVPNInstalled ? "Open LocalDevVPN" : "Get LocalDevVPN (App Store)",
                            systemImage: localDevVPNInstalled ? "lock.shield.fill" : "arrow.down.app.fill"
                        )
                    }
                } header: {
                    Text("Tunnel")
                } footer: {
                    Text("Connect LocalDevVPN before teleporting. Default tunnel IP is 10.7.0.1. Start a spoof on Wi‑Fi first; it can keep working on cellular afterward.")
                }

                Section {
                    if let home = session.home {
                        LabeledContent("Zuhause", value: home.name)
                    }
                    PlaceSearchField(prompt: "Adresse suchen") { name, coordinate in
                        session.setHome(name: name, coordinate: coordinate)
                    }
                    if let pin = session.pin {
                        Button("Aktuellen Pin als Zuhause speichern") {
                            session.setHome(name: session.suggestedFavoriteName(for: pin), coordinate: pin)
                        }
                    }
                    if session.home != nil {
                        Button("Zuhause entfernen", role: .destructive) {
                            session.removeHome()
                        }
                    }
                } header: {
                    Text("Zuhause")
                } footer: {
                    Text("Der Button Zuhause teleportiert dich direkt dorthin. Dein echter Standort kommt erst mit Echter Standort zurück.")
                }

                Section {
                    ForEach(session.shortcuts) { place in
                        Text(place.name)
                            .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                                Button(role: .destructive) {
                                    session.removeShortcut(place)
                                } label: {
                                    Label("Löschen", systemImage: "trash.fill")
                                }
                                Button {
                                    shortcutToRename = place
                                    shortcutName = place.name
                                } label: {
                                    Label("Umbenennen", systemImage: "pencil")
                                }
                                .tint(.gray)
                            }
                    }
                    if session.shortcuts.count < SpoofSession.maxShortcuts {
                        PlaceSearchField(prompt: "Ort für neuen Shortcut suchen") { name, coordinate in
                            session.addShortcut(name: name, coordinate: coordinate)
                        }
                    }
                } header: {
                    Text("Shortcuts (\(session.shortcuts.count)/\(SpoofSession.maxShortcuts))")
                } footer: {
                    Text("Shortcuts erscheinen unten auf der Karte. Beim Antippen fährst du mit 20 km/h die Route dorthin und bleibst am Ziel simuliert. Zum Bearbeiten nach links wischen.")
                }

                Section {
                    Toggle("Eigenes Tempo", isOn: $session.customSpeedEnabled)
                    if session.customSpeedEnabled {
                        Slider(value: $session.customSpeedKmh, in: SpoofSession.customSpeedRange, step: 1)
                        LabeledContent("Tempo") {
                            HStack(spacing: 4) {
                                TextField("30", text: $speedText)
                                    .keyboardType(.decimalPad)
                                    .multilineTextAlignment(.trailing)
                                    .frame(width: 72)
                                    .onChange(of: speedText) { _, value in
                                        if let speed = parsedSpeed(value),
                                           SpoofSession.customSpeedRange.contains(speed) {
                                            session.customSpeedKmh = speed
                                        }
                                    }
                                Text("km/h").foregroundStyle(.secondary)
                            }
                        }
                    }
                } header: {
                    Text("Tempo")
                } footer: {
                    Text("Gilt für Routen und Joystick, 1 bis 500 km/h. Shortcuts fahren immer 20 km/h.")
                }

                Section("Fahrverhalten") {
                    DrivingBehaviorFields()
                }

                Section {
                    Toggle("Ankunft in der Dynamic Island", isOn: $session.liveActivityEnabled)
                } footer: {
                    Text("Zeigt während einer Fahrt Arriving in … at … an.")
                }

                Section("Datenschutz") {
                    Text("Orte bleiben auf dem iPhone. Keine Analyse, kein Konto. Nur beim Planen wird der Routenverlauf an OpenStreetMap geschickt, um Ampeln zu finden.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }

                Section("Über die App") {
                    LabeledContent("Version", value: appVersion)
                    LabeledContent("Engine", value: "idevice DVT location simulation")
                    Text("Location Larper by yungmiami. Basiert auf Location Larper von ChrisMack32 (MIT), Standort über idevice (MIT).")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }

            }
            .navigationTitle("Optionen")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Fertig") {
                        TunnelConfig.setTargetIP(tunnelIP)
                        dismiss()
                    }
                }
            }
            .sheet(isPresented: $showImporter) {
            PairingDocumentPicker(
                onPick: { url in
                    showImporter = false
                    do {
                        try pairing.importPairing(from: url)
                    } catch {
                        session.lastError = error.localizedDescription
                    }
                },
                onCancel: { showImporter = false }
            )
            .ignoresSafeArea()
        }
            .sheet(isPresented: $showPairOnDevice) {
                PairOnDeviceView()
                    .environmentObject(pairing)
            }
            .alert("Shortcut umbenennen", isPresented: Binding(
                get: { shortcutToRename != nil },
                set: { if !$0 { shortcutToRename = nil } }
            )) {
                TextField("Name", text: $shortcutName)
                Button("Abbrechen", role: .cancel) { shortcutToRename = nil }
                Button("Speichern") {
                    if let place = shortcutToRename {
                        session.renameShortcut(place, to: shortcutName)
                    }
                    shortcutToRename = nil
                }
            }
            .onAppear {
                localDevVPNInstalled = LocalDevVPN.isInstalled
                speedText = formattedSpeed(session.customSpeedKmh)
            }
            .onChange(of: session.customSpeedKmh) { _, value in
                if parsedSpeed(speedText) != value {
                    speedText = formattedSpeed(value)
                }
            }
            .onChange(of: scenePhase) { _, phase in
                if phase == .active {
                    localDevVPNInstalled = LocalDevVPN.isInstalled
                }
            }
        }
    }

    private func parsedSpeed(_ text: String) -> Double? {
        Double(text.replacingOccurrences(of: ",", with: "."))
    }

    private func formattedSpeed(_ speed: Double) -> String {
        speed.rounded() == speed ? String(format: "%.0f", speed) : String(format: "%.1f", speed)
    }
}

struct PlacesView: View {
    @EnvironmentObject private var session: SpoofSession
    @EnvironmentObject private var pairing: PairingStore
    @Environment(\.dismiss) private var dismiss

    @State private var placeToRename: SavedPlace?
    @State private var renameText = ""

    var body: some View {
        NavigationStack {
            List {
                Section("Favoriten") {
                    if session.favorites.isEmpty {
                        Text("Tippe auf der Karte auf den Stern, um einen Pin zu speichern.")
                            .foregroundStyle(.secondary)
                    }
                    ForEach(session.favorites) { place in
                        placeButton(place)
                            .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                                Button(role: .destructive) {
                                    session.removeFavorite(place)
                                } label: {
                                    Label("Delete", systemImage: "trash.fill")
                                }
                                Button {
                                    placeToRename = place
                                    renameText = place.name
                                } label: {
                                    Label("Rename", systemImage: "pencil")
                                }
                                .tint(.gray)
                            }
                    }
                }

                Section("Zuletzt") {
                    if session.recents.isEmpty {
                        Text("Hier erscheinen deine letzten Orte.")
                            .foregroundStyle(.secondary)
                    }
                    ForEach(session.recents) { place in
                        placeButton(place)
                            .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                                Button(role: .destructive) {
                                    session.removeRecent(place)
                                } label: {
                                    Label("Delete", systemImage: "trash.fill")
                                }
                            }
                    }
                }
            }
            .navigationTitle("Orte")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Fertig") { dismiss() }
                }
            }
            .alert("Rename Favorite", isPresented: Binding(
                get: { placeToRename != nil },
                set: { if !$0 { placeToRename = nil } }
            )) {
                TextField("Name", text: $renameText)
                Button("Cancel", role: .cancel) {
                    placeToRename = nil
                }
                Button("Save") {
                    if let place = placeToRename {
                        session.renameFavorite(place, to: renameText)
                    }
                    placeToRename = nil
                }
            } message: {
                Text("Choose a name you’ll recognize later.")
            }
        }
    }

    private func placeButton(_ place: SavedPlace) -> some View {
        Button {
            session.teleport(to: place.coordinate, pairing: pairing)
            dismiss()
        } label: {
            VStack(alignment: .leading, spacing: 2) {
                Text(place.name).foregroundStyle(.primary)
                Text(String(format: "%.5f, %.5f", place.latitude, place.longitude))
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
            }
        }
    }
}
