import SwiftUI

/// The scroll view itself observes nothing: the sections below re-render on every store/band update, and doing that
/// to the ScrollView itself reset its scroll position back to the top.
struct DeviceView: View {
    var body: some View {
        ScrollView {
            DeviceSections()
                .padding(.horizontal, 20)
                .padding(.top, 8)
                .padding(.bottom, 24)
        }
        .screenBackground()
        
    }
}

struct DeviceSections: View {
    @EnvironmentObject private var band: BandManager
    @EnvironmentObject private var store: DisplayStore
    @EnvironmentObject private var router: Router

    var body: some View {
        VStack(spacing: 16) {
            let state = store.linkState(at: Date())
            VStack(spacing: 16) {
                header(state)
                if let error = band.error { attention(error) }
                bandCard(state)
            }
            if !band.hasSavedBand {
                Button("Set up your band") { router.showingBandSetup = true }
                    .buttonStyle(PillButtonStyle())
                    .disabled(band.activeWorkout != nil)
            }
            DeviceSettingsCard()
            advancedRow
            AboutRow()
        }
    }

    private func header(_ state: LinkState) -> some View {
        HStack(alignment: .bottom) {
            Text("Device").font(Typo.number(42))
            Spacer()
            ConnectionChip(state: state)
        }
    }

    private func attention(_ message: String) -> some View {
        Card(radius: 20, stroke: Palette.calories.opacity(0.6)) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(Palette.calories)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Needs attention").font(Typo.body(14, weight: .semibold))
                    Text(message).font(Typo.body(13)).foregroundStyle(Palette.secondary)
                }
            }
        }
        .accessibilityElement(children: .combine)
    }

    // MARK: Band

    private func bandCard(_ state: LinkState) -> some View {
        Card(padding: 18) {
            VStack(spacing: 16) {
                HStack(spacing: 18) {
                    strapIllustration(state)
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Your band").sectionLabel(size: 11, tracking: 2)
                        Text(band.savedBandName ?? band.selected?.name ?? (band.hasSavedBand ? "WHOOP 4.0" : "No band paired")).font(Typo.number(26))
                            .minimumScaleFactor(0.7).lineLimit(2)
                        Text(band.ready && !band.syncing ? "Connected" : band.status).font(Typo.body(12)).foregroundStyle(Palette.muted)
                    }
                    Spacer(minLength: 0)
                }
                if band.otherAppLikely && !band.ready {
                    Text("Still can't find your band. Close the WHOOP app (swipe it away) and keep the band near your phone.")
                        .font(Typo.body(12, weight: .medium)).foregroundStyle(Palette.calories).frame(maxWidth: .infinity, alignment: .leading)
                }
                bandStatusRow
                Hairline()
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Last synced").sectionLabel(size: 11, tracking: 2)
                        TimelineView(.periodic(from: .now, by: 30)) { context in
                            Text(lastSyncText(now: context.date)).font(Typo.body(14, weight: .semibold))
                        }
                    }
                    Spacer()
                    syncControls
                }
            }
        }
    }

    /// A fabric strap with a slim sensor pod and one status light: a band, not a watch face.
    /// Battery, wrist and charging, shown only for what the band has reported.
    @ViewBuilder private var bandStatusRow: some View {
        let items = statusItems
        if !items.isEmpty {
            Hairline()
            HStack(spacing: 16) {
                ForEach(items, id: \.1) { item in
                    HStack(spacing: 6) {
                        Image(systemName: item.0).font(.system(size: 14, weight: .semibold)).foregroundStyle(item.2)
                        Text(item.1).font(Typo.body(13, weight: .semibold))
                    }
                }
                Spacer(minLength: 0)
            }
        }
    }
    private var statusItems: [(String, String, Color)] {
        var items: [(String, String, Color)] = []
        if let percent = band.batteryPercent, band.ready || band.batteryDate.map({ Date().timeIntervalSince($0) < 3600 }) ?? false {
            let symbol = band.charging == true ? "battery.100.bolt" : percent < 20 ? "battery.25" : percent < 60 ? "battery.50" : "battery.100"
            items.append((symbol, "\(Int(percent.rounded()))%" + (band.charging == true ? " · Charging" : ""), percent < 20 ? Palette.red : Palette.green))
        } else if band.charging == true { items.append(("battery.100.bolt", "Charging", Palette.green)) }
        if band.ready, let wrist = band.onWrist {
            items.append((wrist ? "hand.raised.fill" : "hand.raised.slash", wrist ? "On wrist" : "Off wrist", wrist ? Palette.green : Palette.muted))
        }
        return items
    }

    private func strapIllustration(_ state: LinkState) -> some View {
        ZStack {
            RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color(hex: 0x232D34)).frame(width: 34, height: 132)
            VStack(spacing: 0) {
                ForEach(0..<2, id: \.self) { _ in Spacer(); Rectangle().fill(Color(hex: 0x2E3A42)).frame(width: 34, height: 2) }
                Spacer().frame(height: 84)
                ForEach(0..<2, id: \.self) { _ in Rectangle().fill(Color(hex: 0x2E3A42)).frame(width: 34, height: 2); Spacer() }
            }
            .frame(height: 132).clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Palette.background)
                .overlay { RoundedRectangle(cornerRadius: 10, style: .continuous).stroke(Color(hex: 0x3A464F), lineWidth: 2) }
                .frame(width: 48, height: 32)
            Circle().fill(state.color.opacity(0.25)).frame(width: 20, height: 20)
            Circle().fill(state.color).frame(width: 8, height: 8)
        }
        .frame(width: 84, height: 132)
        .accessibilityHidden(true)
    }

    private func lastSyncText(now: Date) -> String {
        guard let last = band.lastSync else { return "Not synced yet" }
        if now.timeIntervalSince(last) < 60 { return "Just now" }
        return RelativeDateTimeFormatter().localizedString(for: last, relativeTo: now)
    }

    @ViewBuilder private var syncControls: some View {
        if band.syncing {
            HStack(spacing: 10) {
                ProgressView().tint(Palette.text)
                Button("Stop") { band.stopSync() }
                    .font(Typo.body(14, weight: .semibold)).foregroundStyle(Palette.muted).frame(minWidth: 44, minHeight: 44)
            }
        } else {
            Button {
                band.sync()
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "arrow.triangle.2.circlepath").font(.system(size: 15, weight: .bold))
                    Text("Sync now")
                }
                .padding(.horizontal, 20)
            }
            .buttonStyle(PillButtonStyle(height: 48))
            .fixedSize()
            .disabled(!band.ready || band.repairingClock)
            .opacity(band.ready ? 1 : 0.45)
        }
    }

    // MARK: Settings

    private var advancedRow: some View {
        NavigationLink { AdvancedView() } label: {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Band settings").font(Typo.body(14, weight: .semibold)).foregroundStyle(Palette.text)
                    Text("Calibration and band clock").font(Typo.body(12)).foregroundStyle(Palette.muted)
                }
                Spacer()
                Image(systemName: "chevron.right").font(.system(size: 13, weight: .bold)).foregroundStyle(Palette.muted)
            }
            .padding(.horizontal, 16)
            .frame(minHeight: 60)
            .overlay { RoundedRectangle(cornerRadius: 20, style: .continuous).stroke(Palette.hairline, lineWidth: 1) }
            .contentShape(Rectangle())
        }
        .buttonStyle(CardPressStyle())
    }
}

// MARK: - Settings pages

/// Own view so its UserDefaults-backed toggles do not re-render (and reset the scroll of) the whole Device screen.
struct DeviceSettingsCard: View {
    @AppStorage("detectionEnabled") private var detectionEnabled = true
    @AppStorage(HealthEngine.profileKey) private var profileData = Data()
    @AppStorage(UnitSystem.key) private var unitRaw = UnitSystem.metric.rawValue
    private var profile: UserProfile? { try? JSONDecoder().decode(UserProfile.self, from: profileData) }

    var body: some View {
        Card(padding: 0, radius: 24) {
            VStack(spacing: 0) {
                NavigationLink { ProfileView() } label: {
                    SettingLinkLabel(title: "Profile", subtitle: profile.map { "Age \($0.ageYears) · \(UnitSystem.current.weightText($0.weightKg)) · \(UnitSystem.current.heightText($0.heightCm))" } ?? "Add yours for calories, strain and zones",
                                     value: profile == nil ? "Set up" : "")
                }
                .buttonStyle(CardPressStyle()).padding(.horizontal, 16)
                Hairline().padding(.horizontal, 16)
                SettingToggleRow(title: "Workout detection", subtitle: "Spot workouts automatically and tell me", isOn: $detectionEnabled)
                    .padding(.horizontal, 16)
                    .onChange(of: detectionEnabled) { _, on in if on { Task { await NotificationService.shared.requestAuthorization() } } }
                Hairline().padding(.horizontal, 16)
                NavigationLink { NotificationSettingsView() } label: {
                    SettingLinkLabel(title: "Notifications", subtitle: "Workouts, sleep and sync")
                }
                .buttonStyle(CardPressStyle()).padding(.horizontal, 16)
                Hairline().padding(.horizontal, 16)
                NavigationLink { PreferencesView() } label: {
                    SettingLinkLabel(title: "Preferences", subtitle: "Units, max heart rate, your data")
                }
                .buttonStyle(CardPressStyle()).padding(.horizontal, 16)
            }
        }
    }
}

/// The less-used switches, one tap away from Device.
struct PreferencesView: View {
    @AppStorage("liveActivityEnabled") private var lockScreenEnabled = true
    @AppStorage(Haptics.key) private var hapticsEnabled = true
    @AppStorage(UnitSystem.key) private var unitRaw = UnitSystem.metric.rawValue
    @EnvironmentObject private var band: BandManager
    @EnvironmentObject private var personal: Personalization
    @State private var exportURL: URL?
    @State private var showShare = false
    @State private var confirmDelete = false
    @State private var deleted = false

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                Card(padding: 0, radius: 24) {
                    VStack(spacing: 0) {
                        HStack {
                            Text("Units").font(Typo.body(15, weight: .semibold))
                            Spacer()
                            Picker("Units", selection: $unitRaw) { ForEach(UnitSystem.allCases) { Text($0.title).tag($0.rawValue) } }
                                .pickerStyle(.menu).tint(Palette.text)
                        }
                        .padding(.horizontal, 16).frame(minHeight: 60)
                        Hairline().padding(.horizontal, 16)
                        NavigationLink { MaxHeartRateView() } label: {
                            SettingLinkLabel(title: "Max heart rate", subtitle: "Sets your five zones", value: String(ZoneConfig.maxHR))
                        }
                        .buttonStyle(CardPressStyle()).padding(.horizontal, 16)
                        Hairline().padding(.horizontal, 16)
                        SettingToggleRow(title: "Workouts on lock screen", subtitle: "Live heart rate and time while you train", isOn: $lockScreenEnabled).padding(.horizontal, 16)
                        Hairline().padding(.horizontal, 16)
                        SettingToggleRow(title: "Haptics", subtitle: "Taps and buzzes for buttons and changes", isOn: $hapticsEnabled).padding(.horizontal, 16)
                    }
                }
                Card(radius: 24) {
                    VStack(alignment: .leading, spacing: 12) {
                        Text("Your data").sectionLabel(size: 12, tracking: 1.8)
                        Text("Everything Pulse knows stays on this iPhone. You can take a copy, or erase it all.").font(Typo.body(13)).foregroundStyle(Palette.muted)
                        Button { exportData() } label: { Label("Export my data", systemImage: "square.and.arrow.up") }
                            .buttonStyle(PillButtonStyle(kind: .secondary, height: 52))
                        Button(role: .destructive) { confirmDelete = true } label: { Text("Delete all my data") }
                            .font(Typo.body(15, weight: .semibold)).foregroundStyle(Palette.red).frame(maxWidth: .infinity, minHeight: 48)
                        if deleted { Text("Everything was deleted. Pulse will close so it can start fresh. Open it again to set up.").font(Typo.body(12)).foregroundStyle(Palette.calories) }
                    }
                }
            }
            .padding(20)
        }
        .screenBackground()
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { ToolbarItem(placement: .principal) { Text("Preferences").font(Typo.label(16, weight: .bold)) } }
        
        .sheet(isPresented: $showShare) { if let exportURL { ShareSheet(items: [exportURL]) } }
        .confirmationDialog("Delete all your data?", isPresented: $confirmDelete, titleVisibility: .visible) {
            Button("Delete everything", role: .destructive) { eraseEverything() }
        } message: { Text("This removes your heart-rate history, sleep, workouts, profile and settings, and forgets your band. It can't be undone.") }
    }

    private func exportData() {
        let profile = HealthEngine.loadProfile()
        if let url = personal.exportFile(profile: profile, workouts: band.workouts) { exportURL = url; showShare = true; Haptics.success() }
    }

    private func eraseEverything() {
        band.eraseAllData(); personal.eraseAll()
        let defaults = UserDefaults.standard
        for key in defaults.dictionaryRepresentation().keys where !key.hasPrefix("Apple") && !key.hasPrefix("NS") { defaults.removeObject(forKey: key) }
        deleted = true; Haptics.success()
        Task { try? await Task.sleep(for: .seconds(2)); exit(0) }
    }
}

struct ShareSheet: UIViewControllerRepresentable {
    let items: [Any]
    func makeUIViewController(context: Context) -> UIActivityViewController { UIActivityViewController(activityItems: items, applicationActivities: nil) }
    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}

struct NotificationSettingsView: View {
    @AppStorage("notifyDetections") private var detections = true
    @AppStorage("notifyWorkoutSaved") private var saved = true
    @AppStorage("notifySleep") private var sleep = true
    @AppStorage("notifyRecovery") private var recovery = true

    private func requestIfOn(_ on: Bool) { if on { Task { await NotificationService.shared.requestAuthorization() } } }

    var body: some View {
        ScrollView {
            Card(padding: 0) {
                VStack(spacing: 0) {
                    SettingToggleRow(title: "Workout detected", subtitle: "When your heart rate looks like a workout", isOn: $detections).padding(.horizontal, 16)
                    Hairline().padding(.horizontal, 16)
                    SettingToggleRow(title: "Workout saved", subtitle: "Duration, strain and calories when you finish", isOn: $saved).padding(.horizontal, 16)
                    Hairline().padding(.horizontal, 16)
                    SettingToggleRow(title: "Sleep recorded", subtitle: "Time asleep and performance each morning", isOn: $sleep).padding(.horizontal, 16)
                    Hairline().padding(.horizontal, 16)
                    SettingToggleRow(title: "Recovery ready", subtitle: "Your recovery score once last night is scored", isOn: $recovery).padding(.horizontal, 16)
                }
            }
            .onChange(of: detections) { _, on in requestIfOn(on) }
            .onChange(of: saved) { _, on in requestIfOn(on) }
            .onChange(of: sleep) { _, on in requestIfOn(on) }
            .onChange(of: recovery) { _, on in requestIfOn(on) }
            .padding(20)
        }
        .screenBackground()
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { ToolbarItem(placement: .principal) { Text("Notifications").font(Typo.label(16, weight: .bold)) } }
        
    }
}

struct MaxHeartRateView: View {
    @AppStorage(ZoneConfig.maxHRKey) private var stored = 0
    @AppStorage(HealthEngine.profileKey) private var profileData = Data()
    private var profile: UserProfile? { try? JSONDecoder().decode(UserProfile.self, from: profileData) }
    private var value: Int {
        if let profile, profile.validationError == nil { return Zones.maximum(profile) }
        return stored >= 120 && stored <= 230 ? stored : 190
    }
    private func set(_ new: Int) {
        if var profile, profile.validationError == nil, (100...240).contains(new), profile.restingHROverride.map({ new > $0 }) ?? true {
            profile.maxHROverride = new
            if let data = try? JSONEncoder().encode(profile) { profileData = data }
        } else { stored = new }
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                Card {
                    VStack(spacing: 14) {
                        Text("Max heart rate").sectionLabel(size: 12, tracking: 1.8)
                        Text("\(value)").font(Typo.number(72))
                        Stepper("Max heart rate", value: Binding(get: { value }, set: { set($0); Haptics.select() }), in: 120...230)
                            .labelsHidden()
                        Text(profile == nil ? "Your five zones are set as a share of this number. Add a profile to set it from your age."
                             : profile?.maxHROverride == nil ? "Based on your age. Adjust it if you know your real maximum."
                             : "Set by you. Your five zones are a share of this number.")
                            .font(Typo.body(12)).foregroundStyle(Palette.muted).multilineTextAlignment(.center)
                        if var current = profile, current.maxHROverride != nil {
                            Button("Use my age-based value") {
                                current.maxHROverride = nil
                                if let data = try? JSONEncoder().encode(current) { profileData = data }
                            }
                            .font(Typo.body(13, weight: .semibold)).frame(minHeight: 44)
                        }
                    }
                    .frame(maxWidth: .infinity)
                }
                Card {
                    VStack(spacing: 12) {
                        ForEach(ZoneBand.allCases.reversed()) { band in
                            HStack {
                                RoundedRectangle(cornerRadius: 3).fill(band.color).frame(width: 10, height: 10)
                                Text(band.title).font(Typo.body(14, weight: .medium))
                                Spacer()
                                Text("\(band.floorBPM(maxHR: value))–\(band.ceilingBPM(maxHR: value)) BPM").font(Typo.body(14)).foregroundStyle(Palette.muted)
                            }
                            .accessibilityElement(children: .combine)
                        }
                    }
                }
            }
            .padding(20)
        }
        .screenBackground()
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { ToolbarItem(placement: .principal) { Text("Max heart rate").font(Typo.label(16, weight: .bold)) } }
        
    }
}

// MARK: - Advanced (the former developer screen, moved off the main path)

struct AdvancedView: View {
    var body: some View {
        ScrollView {
            AdvancedSections().padding(20).padding(.bottom, 24)
        }
        .screenBackground()
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { ToolbarItem(placement: .principal) { Text("Band settings").font(Typo.label(16, weight: .bold)) } }
        
    }
}

/// Re-renders with the band's diagnostics; kept out of the ScrollView so scrolling is not reset.
struct AdvancedSections: View {
    @EnvironmentObject private var band: BandManager
    @EnvironmentObject private var router: Router
    @AppStorage("developerMode") private var developerMode = false

    var body: some View {
        VStack(spacing: 16) {
                if band.hasSavedBand {
                    Card {
                        Button("Replace band") { router.showingBandSetup = true }
                            .buttonStyle(PillButtonStyle(kind: .secondary, height: 48))
                            .disabled(band.activeWorkout != nil)
                    }
                }
                Card(padding: 0) {
                    NavigationLink { CalibrationView() } label: { SettingLinkLabel(title: "Calibration", subtitle: "Baselines, zones and learning progress") }
                        .buttonStyle(CardPressStyle()).padding(.horizontal, 16)
                }
                Card {
                    VStack(alignment: .leading, spacing: 12) {
                        Text("Band time").sectionLabel(size: 12, tracking: 1.8)
                        Text(band.clockStatus).font(Typo.body(14))
                        Button("Check now") { band.checkClock() }
                            .buttonStyle(PillButtonStyle(kind: .secondary, height: 48))
                            .disabled(!band.ready || band.syncing || band.repairingClock)
                        Text("Checked each time the band connects, and set to your iPhone's time if it is off.")
                            .font(Typo.body(12)).foregroundStyle(Palette.muted)
                    }
                }
                if developerMode {
                Card {
                    VStack(alignment: .leading, spacing: 12) {
                        Text("Live HR during sync").font(.headline)
                        Text("Checks whether standard Bluetooth heart-rate readings arrive while Pulse downloads history. Keep Pulse open and wear the band during the check.")
                            .font(.subheadline).foregroundStyle(.secondary)
                        Button("Test live HR during sync") { band.checkLiveDuringSync() }
                            .buttonStyle(PillButtonStyle(kind: .secondary, height: 48))
                            .disabled(!band.canCheckLiveSync)
                        if band.syncing, let sample = band.liveSamples.last {
                            TimelineView(.periodic(from: .now, by: 1)) { context in
                                if context.date.timeIntervalSince(sample.date) <= 10 {
                                    Label("\(sample.bpm) BPM · Syncing history", systemImage: "heart")
                                } else {
                                    Text("Syncing history · Waiting for fresh HR")
                                }
                            }
                            .font(.subheadline)
                        }
                        if let report = band.liveSyncReport {
                            Text(report).font(.subheadline).textSelection(.enabled)
                            ShareLink(item: report) { Label("Share check result", systemImage: "square.and.arrow.up") }
                        }
                    }
                }
                ConnectionLogCard(log: band.log)
                Card {
                    VStack(alignment: .leading, spacing: 12) {
                        Text("Live diagnostics").sectionLabel(size: 12, tracking: 1.8)
                        ShareLink(item: band.liveDiagnostics) { Label("Share live diagnostics", systemImage: "square.and.arrow.up") }
                            .font(Typo.body(14, weight: .semibold)).frame(minHeight: 44)
                        DisclosureGroup("Show details") {
                            Text(band.liveDiagnostics).font(.system(size: 11, design: .monospaced)).foregroundStyle(Palette.secondary)
                                .textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading).padding(.top, 8)
                        }
                        .font(Typo.body(13)).tint(Palette.muted)
                    }
                }
                Card {
                    VStack(alignment: .leading, spacing: 12) {
                        Text("Saved records").sectionLabel(size: 12, tracking: 1.8)
                        row("Valid frames this session", band.packetCount)
                        row("Saved heart rate readings", band.samples.count)
                        HStack {
                            Text("Typical gap between history readings").font(Typo.body(13)).foregroundStyle(Palette.muted)
                            Spacer()
                            Text(HRTimeline.medianGapSeconds(band.samples).map { "\(Int($0.rounded())) s" } ?? "—").font(Typo.body(13, weight: .semibold))
                        }
                        row("History records this sync", band.syncRecords)
                        row("Records without decoded heart rate", band.rejectedRecords)
                        Hairline()
                        Button("Reprocess saved records") { band.refreshDiagnostics() }
                            .buttonStyle(PillButtonStyle(kind: .secondary, height: 48))
                        ShareLink(item: band.savedDiagnostics) { Label("Share record diagnostics", systemImage: "square.and.arrow.up") }
                            .font(Typo.body(14, weight: .semibold)).frame(minHeight: 44)
                        DisclosureGroup("Show packet details") {
                            Text(band.savedDiagnostics).font(.system(size: 11, design: .monospaced)).foregroundStyle(Palette.secondary)
                                .textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading).padding(.top, 8)
                        }
                        .font(Typo.body(13)).tint(Palette.muted)
                        Text("Raw records are saved on this iPhone before the band is told they were received.")
                            .font(Typo.body(12)).foregroundStyle(Palette.muted)
                    }
                }
                }
        }
    }

    private func row(_ title: String, _ value: Int) -> some View {
        HStack {
            Text(title).font(Typo.body(13)).foregroundStyle(Palette.muted)
            Spacer()
            Text("\(value)").font(Typo.body(13, weight: .semibold))
        }
    }
}

/// Connects, drops, stalled syncs and reconnects, newest last. Survives app restarts.
private struct ConnectionLogCard: View {
    @ObservedObject var log: BLELog

    var body: some View {
        Card {
            VStack(alignment: .leading, spacing: 12) {
                Text("Connection log").sectionLabel(size: 12, tracking: 1.8)
                ShareLink(item: log.text) { Label("Share connection log", systemImage: "square.and.arrow.up") }
                    .font(Typo.body(14, weight: .semibold)).frame(minHeight: 44)
                DisclosureGroup("Show last events") {
                    Text(log.lines.suffix(40).joined(separator: "\n").isEmpty ? log.text : log.lines.suffix(40).joined(separator: "\n"))
                        .font(.system(size: 11, design: .monospaced)).foregroundStyle(Palette.secondary)
                        .textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading).padding(.top, 8)
                }
                .font(Typo.body(13)).tint(Palette.muted)
            }
        }
    }
}


/// Version line and the one honest note about estimates. Tapping the version seven times switches Developer mode on or off.
struct AboutRow: View {
    @AppStorage("developerMode") private var developerMode = false
    @State private var taps = 0
    @State private var toast: String?
    private var version: String {
        let info = Bundle.main.infoDictionary
        return "Pulse \(info?["CFBundleShortVersionString"] as? String ?? "1.0") (\(info?["CFBundleVersion"] as? String ?? "1"))"
    }
    var body: some View {
        VStack(spacing: 6) {
            Button {
                taps += 1
                if taps >= 7 {
                    taps = 0; developerMode.toggle(); Haptics.success()
                    toast = developerMode ? "Developer mode on" : "Developer mode off"
                    Task { try? await Task.sleep(for: .seconds(2)); toast = nil }
                }
            } label: { Text(version).font(Typo.body(12, weight: .medium)).foregroundStyle(Palette.muted).frame(minHeight: 44) }
                .buttonStyle(.plain)
            if let toast { Text(toast).font(Typo.body(12, weight: .semibold)).foregroundStyle(Palette.strain) }
            Text("Pulse shows estimates from your band's heart-rate data. It is not a medical device.")
                .font(Typo.body(11)).foregroundStyle(Palette.muted).multilineTextAlignment(.center)
        }
        .padding(.top, 8)
    }
}
