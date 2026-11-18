import SwiftUI
import CoreBluetooth
import Charts
import BackgroundTasks

@main struct TrackerApp: App {
    @StateObject private var band = BandManager()
    init() {
        // Notification actions must be handled even when the app is launched by tapping one.
        _ = NotificationService.shared
        BGTaskScheduler.shared.register(forTaskWithIdentifier: BandManager.refreshIdentifier, using: nil) { task in
            guard let task = task as? BGAppRefreshTask else { return }
            Task { @MainActor in BandManager.current?.runBackgroundRefresh(task) ?? task.setTaskCompleted(success: false) }
        }
    }
    var body: some Scene { WindowGroup { RootView().environmentObject(band) } }
}

enum BandSetupState: Equatable {
    case idle, looking, waitingForBluetooth(String), confirm(String), connecting, complete, help(String)

    var isActive: Bool { self != .idle && self != .complete }

    var ownsConnection: Bool {
        switch self {
        case .looking, .waitingForBluetooth, .confirm, .connecting: true
        case .idle, .complete, .help: false
        }
    }
}

@MainActor final class BandManager: NSObject, ObservableObject, @preconcurrency CBCentralManagerDelegate, @preconcurrency CBPeripheralDelegate {
    @Published var status = "Not connected"
    @Published var samples: [Sample] = []
    @Published private(set) var bandSetup = BandSetupState.idle
    @Published private(set) var savedBandID = UserDefaults.standard.string(forKey: "bandIdentifier").flatMap(UUID.init(uuidString:))
    @Published private(set) var savedBandName = UserDefaults.standard.string(forKey: "bandName")
    private enum Discovery { case setup, saved }
    private var discovery: Discovery?
    private var setupCandidates: [UUID: CBPeripheral] = [:]
    private var retiringPeripheral: CBPeripheral?
    private var setupConnectTask: Task<Void, Never>?
    @Published var selected: CBPeripheral?
    @Published var liveSamples: [Sample] = []
    @Published var liveMessage = "Waiting for heart-rate service"
    @Published var workouts: [Workout] = []
    @Published var activeWorkout: Workout?
    private var todayVisible = false
    private var appActive = true
    static let refreshIdentifier = "personal.whooptracker.refresh"
    /// The live manager, so a background task launched by the system can reach it.
    static weak var current: BandManager?
    // Hooks for `HealthEngine`. The band only reports events; it contains no health logic.
    var onLiveReading: ((HeartRateReading, Date) -> Void)?
    var onHistoryChanged: (() -> Void)?
    var onWorkoutStarted: ((Workout) -> Void)?
    var onWorkoutEnded: ((Workout) -> Void)?
    var onWorkoutsEdited: (() -> Void)?
    /// Read from the band; `nil` until known. Wrist and charging come from the band's own events.
    @Published var batteryPercent: Double?
    @Published var batteryDate: Date?
    @Published var onWrist: Bool?
    @Published var charging: Bool?
    /// The saved band has not answered for a couple of minutes: usually another app is holding it.
    @Published var otherAppLikely = false
    private var batterySequence: UInt8?
    private var batteryAsked = false
    private var connectHint: Task<Void, Never>?
    func requestBattery() {
        guard ready, !syncing, !batteryAsked else { return }
        batteryAsked = true
        let generation = connectionGeneration
        send(.batteryLevel)
        Task { [weak self] in
            do { try await Task.sleep(for: .seconds(8)) } catch { return }
            guard let self, self.connectionGeneration == generation else { return }
            self.batteryAsked = false
            self.batterySequence = nil
        }
    }
    var onWorkoutPaused: (() -> Void)?
    var onAppActiveChanged: ((Bool) -> Void)?
    /// Database access for the engines. Call only on the main actor.
    var storage: HistoryStore? { historyStore }
    /// Pairing survives a dropped connection.
    var hasSavedBand: Bool {
        #if DEBUG
        if let stage = debugSetupStage { return stage >= 2 }
        #endif
        return savedBandID != nil
    }
    #if DEBUG
    /// `-setupStage N` in demo mode: how many setup steps the band side reports as done.
    var debugSetupStage: Int?
    func applyDebugSetup(_ stage: Int) {
        debugSetupStage = stage
        clockStatus = stage >= 3 ? "The band's time is correct" : "Not checked yet"
        lastSync = stage >= 4 ? Date().addingTimeInterval(-12 * 60) : nil
    }
    #endif
    private var lastAutoAttempt: Date?
    /// Consecutive automatic syncs that stalled. Each one pushes the next automatic attempt further out, so a
    /// band that is not answering is not hammered (connect → sync → stall → retry) until the radio gives up.
    private var autoSyncFailures = 0
    private static let autoSyncBackoff: [TimeInterval] = [120, 300, 900]
    let log = BLELog()
    /// Preflight (hello, name, range, alarm) runs once per connection; a sync after that sends `history` only.
    private var handshakeDone = false
    private var chunkCount = 0
    private var recordsSeen = 0
    private var lastEndCursor: [UInt8]?
    private var noProgressRestarts = 0
    private var restartAttempts = 0
    private var lastAck: (token: [UInt8], sentAt: Date, resent: Bool)?
    private var ackWatch: Task<Void, Never>?
    private var lastReplyAt: Date?
    func setAppActive(_ active: Bool) {
        log.add(active ? "App active" : "App background/inactive")
        appActive = active
        if !active { finishLiveSyncCheck("Check ended when Pulse left the foreground.") }
        updateStreaming(); onAppActiveChanged?(active)
        batteryTimer?.cancel(); batteryTimer = nil
        if active {
            reconnectSavedBand(); refreshBatteryIfStale(); requestAutoSync(.foreground)
            // While the app is open, keep the battery reading at most about 10 minutes old.
            batteryTimer = Task { [weak self] in
                while !Task.isCancelled {
                    try? await Task.sleep(for: .seconds(60))
                    self?.refreshBatteryIfStale()
                }
            }
        } else { scheduleBackgroundRefresh() }
    }
    private var batteryTimer: Task<Void, Never>?
    private func refreshBatteryIfStale() {
        if batteryDate.map({ Date().timeIntervalSince($0) >= 600 }) ?? true { requestBattery() }
    }
    /// Start a history transfer when the policy says one is worth it. Never turns on live streaming.
    func requestAutoSync(_ trigger: SyncPolicy.Trigger) {
        guard ready, historyStore != nil, !repairingClock, !checkingClock, activeWorkout == nil else { return }
        let now = Date()
        if autoSyncFailures > 0, let last = lastAutoAttempt,
           now.timeIntervalSince(last) < Self.autoSyncBackoff[min(autoSyncFailures, Self.autoSyncBackoff.count) - 1] { return }
        guard SyncPolicy.shouldSync(trigger, now: now, lastSuccess: lastSync, lastAttempt: lastAutoAttempt, isSyncing: syncing, lowPower: ProcessInfo.processInfo.isLowPowerModeEnabled) else { return }
        lastAutoAttempt = now
        log.add("Auto sync (\(trigger))")
        sync()
    }
    func scheduleBackgroundRefresh() {
        let request = BGAppRefreshTaskRequest(identifier: Self.refreshIdentifier)
        request.earliestBeginDate = Date().addingTimeInterval(HealthConstants.backgroundSyncAge)
        try? BGTaskScheduler.shared.submit(request)
    }
    /// A system-granted refresh window: sync once within a small budget, then stop cleanly.
    func runBackgroundRefresh(_ task: BGAppRefreshTask) {
        scheduleBackgroundRefresh()
        var finished = false
        func finish(_ success: Bool) { guard !finished else { return }; finished = true; task.setTaskCompleted(success: success) }
        task.expirationHandler = { [weak self] in Task { @MainActor [weak self] in self?.stopSync(); finish(false) } }
        requestAutoSync(.background)
        guard syncing else { finish(true); return }
        Task { @MainActor [weak self] in
            let deadline = Date().addingTimeInterval(HealthConstants.backgroundSyncBudget)
            while let self, self.syncing, Date() < deadline { try? await Task.sleep(for: .seconds(1)) }
            if self?.syncing == true { self?.stopSync(); finish(false) } else { finish(true) }
        }
    }
    @Published var liveDiagnostics = "No live requests yet"
    private var liveTrace: [String] = []
    private var liveWatch: Task<Void, Never>?
    private var connectionWatch: Task<Void, Never>?
    private var pendingSequence: UInt8?
    private func traceLive(_ text: String) {
        liveTrace.append(text); if liveTrace.count > 16 { liveTrace.removeFirst() }
        liveDiagnostics = liveTrace.joined(separator: "\n")
    }
    private struct LiveSyncCheck {
        var firstHistoryAt: TimeInterval?
        var lastReadingAt: TimeInterval?
        var longestGap: TimeInterval = 0
        var readings = 0
        var committedRecords = 0
    }
    private var liveSyncCheck: LiveSyncCheck?
    @Published private(set) var liveSyncReport: String?
    var canCheckLiveSync: Bool {
        ready && appActive && historyStore != nil && !syncing && !repairingClock && !spotChecking && activeWorkout == nil
    }
    private var proprietaryStreaming = false
    /// A short raw light-sensor capture while the wearer is still or asleep (for blood oxygen).
    private var spotChecking = false
    private var opticalUntil: Date?
    private var lastOpticalCapture: Date? = UserDefaults.standard.object(forKey: "lastOpticalCapture") as? Date
    private var hrCharacteristic: CBCharacteristic?
    private let hrService = CBUUID(string: "180D")
    private let hrMeasurement = CBUUID(string: "2A37")
    /// Application Support, or a throwaway folder when launched with `-demoHistory` (debug builds only).
    private lazy var dataDirectory: URL = {
        #if DEBUG
        if CommandLine.arguments.contains("-demoHistory") {
            let folder = FileManager.default.temporaryDirectory.appendingPathComponent("demo-\(ProcessInfo.processInfo.processIdentifier)")
            try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            return folder
        }
        #endif
        return FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
    }()
    private var workoutURL: URL { dataDirectory.appendingPathComponent("workouts.json") }
    func setTodayVisible(_ visible: Bool) { todayVisible = visible; updateStreaming() }
    func checkLiveDuringSync() {
        guard canCheckLiveSync else { return }
        guard hrCharacteristic?.properties.contains(.notify) == true || hrCharacteristic?.properties.contains(.indicate) == true else {
            liveSyncReport = "The standard heart-rate notification characteristic is unavailable. Reconnect and try again."
            return
        }
        liveSyncCheck = LiveSyncCheck()
        liveSyncReport = "Checking standard Bluetooth heart rate during history sync…"
        liveSamples = []
        updateStreaming()
        sync()
    }

    private func countLiveSyncReading() {
        guard var check = liveSyncCheck, let first = check.firstHistoryAt else { return }
        let now = ProcessInfo.processInfo.systemUptime
        check.longestGap = max(check.longestGap, now - (check.lastReadingAt ?? first))
        check.lastReadingAt = now
        check.readings += 1
        liveSyncCheck = check
    }

    private func finishLiveSyncCheck(_ outcome: String) {
        guard let check = liveSyncCheck else { return }
        liveSyncCheck = nil
        let evidence: String
        if let first = check.firstHistoryAt, check.committedRecords > 0 {
            let now = ProcessInfo.processInfo.systemUptime
            let gap = max(check.longestGap, now - (check.lastReadingAt ?? first))
            let duration = Int(now - first)
            evidence = "\(check.readings) standard HR readings during \(duration) s of history transfer · \(check.committedRecords) history records saved · longest observed HR gap \(Int(gap.rounded())) s."
        } else {
            evidence = "Inconclusive. No history records were saved during this check. Wear the band for a few minutes, then try again."
        }
        let report = "\(outcome) \(evidence)"
        liveSyncReport = report
        log.add("Live HR and sync check: " + report)
    }

    private func updateStreaming() {
        let wanted = (todayVisible && appActive) || activeWorkout != nil || spotChecking
        let standardWanted = wanted || liveSyncCheck != nil
        if let selected, let hrCharacteristic, hrCharacteristic.isNotifying != standardWanted {
            selected.setNotifyValue(standardWanted, for: hrCharacteristic)
        }
        guard liveSyncCheck == nil, ready, !syncing, !repairingClock, proprietaryStreaming != wanted else { return }
        proprietaryStreaming = wanted
        send(.realtimeHR, body: [wanted ? 1 : 0])
        send(.rawRealtime, body: [wanted ? 1 : 0])
        send(.optical, body: [1, wanted ? 1 : 0])
        liveMessage = wanted ? "Live stream requested · waiting for band" : "Live stream paused"
        traceLive(wanted ? "Starting wrist-gated HR + R10 stream" : "Stopping live stream (not on a live screen)")
        liveWatch?.cancel()
        if wanted {
            liveWatch = Task {
                while !Task.isCancelled {
                    do { try await Task.sleep(for: .seconds(10)) } catch { return }
                    guard proprietaryStreaming, selected?.state == .connected else { return }
                    if liveSamples.last.map({ Date().timeIntervalSince($0.date) > 10 }) ?? true {
                        liveMessage = "No fresh live HR received · see Device → Live diagnostics"
                    }

                }
            }
        }
    }
    // MARK: Optical spot checks

    /// Keeps up to 60 s of raw light-sensor frames at most every 30 minutes, whether the stream was
    /// started by a spot check or by an open live screen.
    private func captureOptical(_ frame: [UInt8]) {
        let now = Date()
        if opticalUntil.map({ now > $0 }) ?? true {
            guard lastOpticalCapture.map({ now.timeIntervalSince($0) >= 30 * 60 }) ?? true else { return }
            opticalUntil = now.addingTimeInterval(60); lastOpticalCapture = now
            UserDefaults.standard.set(now, forKey: "lastOpticalCapture")
            log.add("Optical sample started" + (spotChecking ? " (still or asleep)" : ""))
        }
        do { try historyStore?.saveOptical(frame, at: now) } catch { log.add("Optical sample not saved: \(error.localizedDescription)") }
    }

    /// After a sync, if the last 10 minutes show almost no movement, run the raw stream for about a minute.
    private func maybeSpotCheck() {
        guard ready, !syncing, !repairingClock, !spotChecking, !proprietaryStreaming, activeWorkout == nil, let historyStore else { return }
        let now = Date()
        guard lastOpticalCapture.map({ now.timeIntervalSince($0) >= 30 * 60 }) ?? true else { return }
        guard let minutes = try? historyStore.historyMinutes(from: now.addingTimeInterval(-15 * 60), to: now) else { return }
        let recent = minutes.values.filter { Double($0.minute) * 60 >= now.timeIntervalSince1970 - 12 * 60 }
        let motions = recent.compactMap(\.motion)
        guard motions.count >= 6, motions.allSatisfy({ $0 <= HealthConstants.stillMotion }) else { return }
        spotChecking = true
        log.add("Still for 10 min · starting a 60 s optical sample")
        updateStreaming()
        let generation = connectionGeneration
        Task { [weak self] in
            do { try await Task.sleep(for: .seconds(75)) } catch { return }
            guard let self, self.connectionGeneration == generation, self.spotChecking else { return }
            self.spotChecking = false
            self.updateStreaming()
        }
    }
    private func recordLive(_ reading: HeartRateReading) {
        let now = Date()
        if let last = liveSamples.last, now.timeIntervalSince(last.date) < 0.5 { return }
        let sample = Sample(id: UUID().uuidString, date: now, bpm: reading.bpm)
        liveSamples.append(sample)
        if liveSamples.count > 120 { liveSamples.removeFirst(liveSamples.count - 120) }
        liveMessage = "Live"
        onLiveReading?(reading, now)
        if activeWorkout != nil && activeWorkout?.pausedAt == nil {
            activeWorkout?.readings.append(WorkoutReading(date: now, bpm: sample.bpm))
            if (activeWorkout?.readings.count ?? 0) % 10 == 0 { saveWorkouts() }
        }
    }
    private func saveWorkouts() {
        do { try JSONEncoder().encode(workouts + (activeWorkout.map { [$0] } ?? [])).write(to: workoutURL, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication]) }
        catch { fail("We couldn't save your workout. Please try again.", error) }
    }
    /// Show a plain message to the user and keep the technical reason in the connection log.
    func fail(_ message: String, _ underlying: Error) {
        log.add("\(message) [\(underlying.localizedDescription)]"); error = message
    }
    /// Forget the band, delete every stored reading and workout, and clear settings. The caller restarts the app.
    func eraseAllData() {
        savedBandID = nil
        savedBandName = nil
        bandSetup = .idle
        stopDiscovery()
        retireConnection()
        for key in ["bandIdentifier", "bandName", "lastSync", "wantsConnection"] {
            UserDefaults.standard.removeObject(forKey: key)
        }
        try? historyStore?.eraseAll()
        try? FileManager.default.removeItem(at: workoutURL)
        workouts = []; activeWorkout = nil; samples = []; liveSamples = []; lastSync = nil; batteryPercent = nil; batteryDate = nil
        log.clear()
    }
    func startWorkout(type: String) {
        guard activeWorkout == nil else { return }
        activeWorkout = Workout(type: type); saveWorkouts(); updateStreaming()
        if let activeWorkout { onWorkoutStarted?(activeWorkout) }
    }
    /// Add a finished workout created elsewhere (a confirmed detection).
    func addWorkout(_ workout: Workout) {
        workouts.append(workout); workouts.sort { $0.start < $1.start }; saveWorkouts()
    }
    /// Remove a saved workout. The running workout cannot be removed here.
    func removeWorkout(id: UUID) {
        guard workouts.contains(where: { $0.id == id }) else { return }
        workouts.removeAll { $0.id == id }; saveWorkouts(); onWorkoutsEdited?()
    }
    /// Replace a saved workout (type or times edited by the user).
    func updateWorkout(_ workout: Workout) {
        guard let index = workouts.firstIndex(where: { $0.id == workout.id }) else { return }
        workouts[index] = workout; workouts.sort { $0.start < $1.start }; saveWorkouts(); onWorkoutsEdited?()
    }
    func pauseWorkout() {
        guard var workout = activeWorkout else { return }
        if let pause = workout.pausedAt { workout.pauses = (workout.pauses ?? []) + [DateInterval(start: pause,end: Date())]; workout.pausedSeconds += Date().timeIntervalSince(pause); workout.pausedAt = nil }
        else { workout.pausedAt = Date() }
        activeWorkout = workout; saveWorkouts(); onWorkoutPaused?()
    }
    func finishWorkout() {
        guard var workout = activeWorkout else { return }
        if let pause = workout.pausedAt { workout.pauses = (workout.pauses ?? []) + [DateInterval(start: pause,end: Date())]; workout.pausedSeconds += Date().timeIntervalSince(pause); workout.pausedAt = nil }
        workout.end = Date(); workouts.append(workout); activeWorkout = nil; saveWorkouts(); updateStreaming()
        onWorkoutEnded?(workout)
    }
    @Published var packetCount = 0
    @Published var savedDiagnostics = "No saved frames"
    @Published var syncRecords = 0
    @Published var rejectedRecords = 0
    private var reconnectTask: Task<Void, Never>?
    private var scanTask: Task<Void, Never>?
    private var reconnectDelay = 2
    @Published var error: String?
    private var central: CBCentralManager!
    private var decoders: [CBUUID: FrameDecoder] = [:]
    private let service = CBUUID(string: "61080001-8d6d-82b8-614a-1c8cb0f8dcc6")
    private var historyStore: HistoryStore?
    private var writer: CBCharacteristic?
    private var readyNotifications = Set<CBUUID>()
    private var pendingCommand: HistoryProtocol.Command?
    private var sequence: UInt8 = 0
    private var writes: [(HistoryProtocol.Command, [UInt8])] = []
    private var awaitingWrite = false
    private var connectionGeneration = 0
    private func resetSession() {
        connectionGeneration += 1
        spotChecking = false
        opticalUntil = nil
        finishLiveSyncCheck("Connection ended during the check.")
        // Do not clear lastAutoAttempt here: that made every reconnect start a sync at once, and a band that
        // stalled the last one stalled again, which disconnected it again.
        if syncing { autoSyncFailures += 1; log.add("Session reset during sync") }
        liveWatch?.cancel(); linkProbe?.cancel(); connectionWatch?.cancel(); ackWatch?.cancel(); lastAck = nil; handshakeDone = false
        timeout?.cancel(); clockTask?.cancel(); reconnectTask?.cancel(); setupConnectTask?.cancel()
        syncing = false; repairingClock = false; checkingClock = false; clockSequence = nil; proprietaryStreaming = false
        batch = []; writes = []; awaitingWrite = false; pendingCommand = nil; pendingSequence = nil
        batterySequence = nil; batteryAsked = false; onWrist = nil; charging = nil; connectHint?.cancel(); connectHint = nil
        writer = nil; ready = false; readyNotifications = []; decoders = [:]; hrCharacteristic = nil; liveSamples = []; liveMessage = "Disconnected"
    }
    private var batch: [[UInt8]] = []
    private var timeout: Task<Void, Never>?
    @Published var clockStatus = "Not checked yet"
    @Published var repairingClock = false
    private var checkingClock = false
    private var lastClockRepair: Date?
    private var clockTask: Task<Void, Never>?
    private var clockSequence: UInt8?
    @Published var syncing = false
    @Published var ready = false
    @Published var lastSync: Date?
    private let notifications = [3, 4, 5].map { CBUUID(string: String(format: "610800%02x-8d6d-82b8-614a-1c8cb0f8dcc6", $0)) }

    override init() {
        super.init()
        Self.current = self
        log.add("App launch")
        let directory = dataDirectory
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try FileManager.default.setAttributes([.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication], ofItemAtPath: directory.path)
            historyStore = try HistoryStore(url: directory.appendingPathComponent("history.sqlite"))
            if FileManager.default.fileExists(atPath: workoutURL.path) {
                let saved = try JSONDecoder().decode([Workout].self, from: Data(contentsOf: workoutURL))
                workouts = saved.filter { $0.end != nil }
                activeWorkout = saved.first { $0.end == nil }
            }
            samples = try historyStore?.recent() ?? []
            savedDiagnostics = try historyStore?.diagnostics() ?? "Storage unavailable"
            lastSync = UserDefaults.standard.object(forKey: "lastSync") as? Date
        } catch { fail("We couldn't open your saved data. Restart the app and try again.", error) }
        central = CBCentralManager(delegate: self, queue: .main, options: [CBCentralManagerOptionRestoreIdentifierKey: "personal.whoop.central"])
    }
    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        guard central.state == .poweredOn else {
            stopDiscovery()
            resetSession()
            selected = nil
            retiringPeripheral = nil
            status = bluetoothMessage
            if bandSetup.ownsConnection { bandSetup = .waitingForBluetooth(bluetoothMessage) }
            return
        }
        if bandSetup.ownsConnection { startSetupDiscovery() }
        else { reconnectSavedBand() }
    }

    private var bluetoothMessage: String {
        switch central.state {
        case .unauthorized: "Bluetooth access is off for Pulse. Allow it in iPhone Settings."
        case .poweredOff: "Bluetooth is off. Turn it on to connect your band."
        case .unsupported: "Bluetooth is unavailable on this device."
        default: "Bluetooth is getting ready."
        }
    }

    private func reconnectSavedBand() {
        guard central.state == .poweredOn, !bandSetup.ownsConnection, retiringPeripheral == nil,
              selected == nil, discovery == nil else { return }
        guard let id = savedBandID else { status = "No band set up"; return }
        if let peripheral = central.retrievePeripherals(withIdentifiers: [id]).first {
            openConnection(peripheral)
        } else {
            beginDiscovery(.saved)
        }
    }
    #if DEBUG
    /// Feed a heart-rate reading as if the band had sent it (demo mode only).
    func injectDemoReading(_ bpm: Int) { recordLive(HeartRateReading(bpm: bpm, rrMilliseconds: [])) }
    #endif
    func refreshDiagnostics() {
        do {
            try historyStore?.replaySavedFrames()
            samples = try historyStore?.recent() ?? []
            savedDiagnostics = try historyStore?.diagnostics() ?? "Storage unavailable"
        } catch { fail("We couldn't reach your band. Try again.", error) }
    }
    func beginBandSetup() {
        guard activeWorkout == nil, !bandSetup.ownsConnection else { return }
        error = nil
        bandSetup = .looking
        stopDiscovery()
        retireConnection()
        startSetupDiscovery()
    }

    var bandSetupNeedsSettings: Bool { central.state == .unauthorized }

    func retryBandSetup() {
        guard bandSetup.isActive else { return }
        if case .waitingForBluetooth = bandSetup { startSetupDiscovery() }
        else { beginBandSetup() }
    }

    private func startSetupDiscovery() {
        guard bandSetup.isActive, selected == nil, retiringPeripheral == nil else { return }
        guard central.state == .poweredOn else {
            bandSetup = .waitingForBluetooth(bluetoothMessage)
            return
        }
        setupCandidates.removeAll()
        bandSetup = .looking
        beginDiscovery(.setup)
    }

    func confirmBandSetup() {
        guard case .confirm = bandSetup, setupCandidates.count == 1,
              let peripheral = setupCandidates.values.first, central.state == .poweredOn else { return }
        bandSetup = .connecting
        openConnection(peripheral)
        if peripheral.state != .connected {
            setupConnectTask = Task { [weak self] in
                do { try await Task.sleep(for: .seconds(20)) } catch { return }
                guard let self, self.bandSetup == .connecting else { return }
                self.recoverConnection("The band didn't connect. Keep it nearby and try again.")
            }
        }
    }

    func cancelBandSetup() {
        guard bandSetup.isActive else { return }
        let cancellingConnection = bandSetup.ownsConnection
        bandSetup = .idle
        setupCandidates.removeAll()
        if cancellingConnection {
            stopDiscovery()
            retireConnection()
        }
        reconnectSavedBand()
    }

    private func beginDiscovery(_ purpose: Discovery) {
        stopDiscovery()
        reconnectTask?.cancel()
        discovery = purpose
        status = purpose == .setup ? "Looking for your band…" : "Reconnecting to your band…"
        central.scanForPeripherals(withServices: [service], options: [CBCentralManagerScanOptionAllowDuplicatesKey: false])
        scanTask = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(purpose == .setup ? 8 : 15)) } catch { return }
            guard let self, self.discovery == purpose else { return }
            self.stopDiscovery()
            if purpose == .saved {
                self.scheduleReconnect(waitingForRange: true)
                return
            }
            switch self.setupCandidates.count {
            case 0:
                self.bandSetup = .help("No band found. Charge or wake your band, keep it close, and try again.")
                self.scheduleReconnect()
            case 1: self.bandSetup = .confirm(self.setupCandidates.values.first?.name ?? "WHOOP 4.0")
            default:
                self.bandSetup = .help("More than one band is nearby. Move away from the other bands and try again.")
                self.scheduleReconnect()
            }
        }
    }

    private func stopDiscovery() {
        scanTask?.cancel()
        scanTask = nil
        discovery = nil
        if central.isScanning { central.stopScan() }
    }

    func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral, advertisementData: [String: Any], rssi RSSI: NSNumber) {
        switch discovery {
        case .setup: setupCandidates[peripheral.identifier] = peripheral
        case .saved where peripheral.identifier == savedBandID: openConnection(peripheral)
        default: break
        }
    }

    private func openConnection(_ peripheral: CBPeripheral) {
        guard selected == nil, retiringPeripheral == nil else { return }
        stopDiscovery()
        resetSession()
        selected = peripheral
        peripheral.delegate = self
        error = nil
        if peripheral.state == .connected {
            centralManager(central, didConnect: peripheral)
        } else {
            status = bandSetup.isActive ? "Connecting to your band…" : "Reconnecting to your band…"
            central.connect(peripheral)
            connectHint = Task { [weak self] in
                do { try await Task.sleep(for: .seconds(120)) } catch { return }
                guard let self, !self.ready, self.selected === peripheral else { return }
                self.status = "Band out of reach"
                self.otherAppLikely = true
            }
        }
    }

    private func retireConnection() {
        let old = selected
        selected = nil
        resetSession()
        if let old, old.state != .disconnected {
            retiringPeripheral = old
            central.cancelPeripheralConnection(old)
        }
    }

    private func finishRetirement(_ peripheral: CBPeripheral) -> Bool {
        guard retiringPeripheral === peripheral else { return false }
        retiringPeripheral = nil
        if bandSetup == .looking { startSetupDiscovery() }
        else if !bandSetup.ownsConnection { scheduleReconnect() }
        return true
    }

    private func saveConfirmedBand(_ peripheral: CBPeripheral) {
        let changedBand = savedBandID != peripheral.identifier
        savedBandID = peripheral.identifier
        savedBandName = peripheral.name ?? "WHOOP 4.0"
        UserDefaults.standard.set(peripheral.identifier.uuidString, forKey: "bandIdentifier")
        UserDefaults.standard.set(savedBandName, forKey: "bandName")
        UserDefaults.standard.removeObject(forKey: "wantsConnection")
        setupCandidates.removeAll()
        if changedBand {
            batteryPercent = nil; batteryDate = nil; lastSync = nil
            lastAutoAttempt = nil; autoSyncFailures = 0; lastClockRepair = nil
            UserDefaults.standard.removeObject(forKey: "lastSync")
        }
        bandSetup = .complete
    }
    /// Read the band clock (read-only). If it is off by more than 30 s it is corrected automatically, at most once an hour.
    /// An unreadable clock is reported but never overwritten.
    func checkClock() {
        guard ready, !syncing, !repairingClock, !checkingClock, activeWorkout == nil else { return }
        checkingClock = true; clockStatus = "Checking the band's time…"
        send(.getClock)
        guard checkingClock else { return }
        clockTask?.cancel()
        clockTask = Task {
            do { try await Task.sleep(for: .seconds(8)) } catch { return }
            guard checkingClock else { return }
            checkingClock = false
            clockStatus = "Couldn't read the band's time. Nothing was changed."
            requestAutoSync(appActive ? .foreground : .reconnect)
        }
    }
    private func handleClockReading(_ date: Date) {
        checkingClock = false; clockTask?.cancel()
        let drift = date.timeIntervalSinceNow
        if abs(drift) <= 30 {
            clockStatus = "The band's time is correct"
            requestAutoSync(appActive ? .foreground : .reconnect)
        } else if lastClockRepair.map({ Date().timeIntervalSince($0) > 3600 }) ?? true {
            lastClockRepair = Date()
            clockStatus = "The band's time was off. Correcting…"
            repairClock()
        } else {
            clockStatus = "The band's time is still off. Try again in a moment."
        }
    }
    func repairClock() {
        guard ready, !syncing, !repairingClock else { return }
        checkingClock = false; error = nil; repairingClock = true; clockStatus = "Setting band time…"
        let seconds = UInt32(Date().timeIntervalSince1970)
        send(.setClock, body: HistoryProtocol.clockBody(seconds: seconds))
        guard repairingClock else { return }
        clockTask = Task {
            do { try await Task.sleep(for: .seconds(2)) } catch { return }
            guard repairingClock, selected?.state == .connected else { return }
            clockSequence = sequence
            send(.getClock)
            do { try await Task.sleep(for: .seconds(10)) } catch { return }
            if repairingClock {
                repairingClock = false
                clockStatus = "Time sent to the band. Wear it for a few minutes, then sync."
                requestAutoSync(appActive ? .foreground : .reconnect)
            }
        }
    }
    func sync() {
        guard ready, historyStore != nil, !syncing, !repairingClock else { return }
        if checkingClock { checkingClock = false; clockTask?.cancel(); clockStatus = "Check skipped while syncing" }
        // The band is busiest while streaming live data; a history transfer gets it to itself.
        if proprietaryStreaming {
            proprietaryStreaming = false; liveWatch?.cancel()
            send(.realtimeHR, body: [0]); send(.rawRealtime, body: [0]); send(.optical, body: [1, 0])
            liveMessage = "Live stream paused during sync"; traceLive("Stopping live stream for sync")
        }
        error = nil; syncRecords = 0; rejectedRecords = 0; syncing = true; batch = []; status = "Starting history sync…"
        lastProgress = Date(); chunkCount = 0; recordsSeen = 0; noProgressRestarts = 0; restartAttempts = 0; lastEndCursor = nil
        log.add("Sync started (preflight \(handshakeDone ? "skipped" : "needed"))")
        armTimeout()
        if handshakeDone { status = "Downloading history…"; send(.history) } else { send(.hello) }
    }
    private func send(_ command: HistoryProtocol.Command, body: [UInt8] = []) {
        guard let selected, writer != nil, selected.state == .connected else { fail("Band disconnected"); return }
        writes.append((command, body)); drainWrites()
    }
    private func drainWrites() {
        guard !awaitingWrite, !writes.isEmpty, let selected, let writer, selected.state == .connected else { return }
        let type: CBCharacteristicWriteType = writer.properties.contains(.write) ? .withResponse : .withoutResponse
        if type == .withoutResponse && !selected.canSendWriteWithoutResponse { return }
        let (command, body) = writes.removeFirst()
        if [.realtimeHR, .rawRealtime, .optical].contains(command) {
            traceLive(String(format: "TX opcode %02X body ", command.rawValue) + body.map { String(format: "%02X", $0) }.joined())
        }
        let bytes = HistoryProtocol.command(command, sequence: sequence, body: body)
        guard bytes.count <= selected.maximumWriteValueLength(for: type) else { fail("Band write limit is too small"); return }
        if command == .getClock { clockSequence = sequence }
        if command == .batteryLevel { batterySequence = sequence }
        if syncing && [.hello, .name, .range, .alarm, .history].contains(command) {
            pendingCommand = command; pendingSequence = sequence
        }
        if [.acknowledge, .history, .abort].contains(command) { log.add("TX \(command) seq \(sequence) " + bytes.map { String(format: "%02X", $0) }.joined()) }
        sequence &+= 1
        awaitingWrite = type == .withResponse
        selected.writeValue(Data(bytes), for: writer, type: type)

        if !awaitingWrite { drainWrites() }
    }
    func peripheralIsReady(toSendWriteWithoutResponse peripheral: CBPeripheral) {
        guard peripheral === selected else { return }
        drainWrites()
    }
    /// Sync watchdog: 20 s with nothing at all from the band, or 120 s without the transfer moving forward.
    /// Either one ends the sync only. The connection is dropped only if the band then fails a link check.
    private func armTimeout() {
        timeout?.cancel()
        timeout = Task { [weak self] in
            while true {
                do { try await Task.sleep(for: .seconds(5)) } catch { return }
                guard let self, self.syncing else { return }
                let now = Date()
                let silent = now.timeIntervalSince(self.lastFrameAt ?? .distantPast) > 20 && now.timeIntervalSince(self.lastProgress) > 20
                if silent || now.timeIntervalSince(self.lastProgress) > 120 { self.syncStalled(silent: silent); return }
            }
        }
    }
    private var lastFrameAt: Date?
    private var lastProgress = Date()
    private var linkProbe: Task<Void, Never>?
    private func syncStalled(silent: Bool) {
        let step = pendingCommand.map { "\($0)" } ?? "none"
        log.add("Sync stalled (step \(step), \(silent ? "band silent" : "no progress"))")
        autoSyncFailures += 1; lastAutoAttempt = Date()
        stopSync()
        let retry = Int(Self.autoSyncBackoff[min(autoSyncFailures, Self.autoSyncBackoff.count) - 1] / 60)
        error = "Sync paused. Your data is safe, and we'll try again in about \(retry) min."
        status = "Connected · sync paused"
        probeLink()
    }
    /// Ask the band for a trivial reply. If nothing at all arrives within 6 s the link is dead, so reconnect.
    private func probeLink() {
        guard ready, selected?.state == .connected else { return }
        linkProbe?.cancel()
        linkProbe = Task { [weak self] in
            // Let the band settle after the abort, and only count a real command reply as proof of life.
            do { try await Task.sleep(for: .seconds(2)) } catch { return }
            guard let self, self.ready, !self.syncing else { return }
            let sent = Date()
            self.send(.linkValid)
            do { try await Task.sleep(for: .seconds(6)) } catch { return }
            guard self.ready else { return }
            if (self.lastReplyAt ?? .distantPast) < sent {
                self.log.add("Link check failed")
                self.recoverConnection("The band stopped responding. Saved data is retained; reconnecting automatically.")
            } else {
                self.log.add("Link check ok")
            }
        }
    }
    func stopSync() {
        guard syncing else { return }
        finishLiveSyncCheck("Sync stopped during the check.")
        syncing = false; timeout?.cancel(); ackWatch?.cancel(); lastAck = nil; pendingCommand = nil
        pendingSequence = nil; writes = []
        if selected?.state == .connected, writer != nil { send(.abort) }
        status = "Sync stopped"; batch = []
        updateStreaming()
    }
    private func sendAcknowledge(_ token: [UInt8]) {
        log.add("ACK handed to writer")
        send(.acknowledge, body: [1] + token)
        lastAck = (token, Date(), false)
        armAckWatch()
    }
    /// The band should answer an ACK with the next chunk (or COMPLETE) within seconds. If not, send the same ACK
    /// once more; if that is also ignored, restart the transfer from the band's own cursor.
    private func armAckWatch() {
        ackWatch?.cancel()
        ackWatch = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(5)) } catch { return }
            guard let self, self.syncing, let ack = self.lastAck else { return }
            if !ack.resent {
                self.lastAck = (ack.token, Date(), true)
                self.log.add("No continuation 5 s after ACK; re-sending it")
                self.send(.acknowledge, body: [1] + ack.token)
                self.armAckWatch()
            } else {
                self.log.add("No continuation after re-sent ACK; restarting the transfer")
                self.restartTransfer()
            }
        }
    }
    /// Mid-chunk silence: the band sent a start marker or some records, then nothing. Restart from its cursor.
    private func armChunkWatch() {
        ackWatch?.cancel()
        ackWatch = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(8)) } catch { return }
            guard let self, self.syncing, self.lastAck == nil else { return }
            self.log.add("Band went quiet mid-chunk (\(self.batch.count) frames buffered); restarting the transfer")
            self.restartTransfer()
        }
    }
    private func restartTransfer() {
        lastAck = nil; restartAttempts += 1
        guard restartAttempts <= 20, noProgressRestarts < 3 else { syncStalled(silent: false); return }
        batch = []; writes = []; pendingCommand = nil; pendingSequence = nil
        send(.abort)
        lastProgress = Date()
        Task { [weak self] in
            do { try await Task.sleep(for: .seconds(2)) } catch { return }
            guard let self, self.syncing, self.ready else { return }
            self.log.add("Restart \(self.restartAttempts): requesting history again")
            self.lastProgress = Date()
            self.send(.history)
        }
    }
    private func fail(_ message: String) {
        if checkingClock { checkingClock = false; clockTask?.cancel(); clockStatus = "Couldn't check the band's time" }
        if repairingClock { repairingClock = false; clockTask?.cancel(); clockStatus = "Couldn't set the band's time" }
        stopSync(); error = message
    }
    func peripheral(_ peripheral: CBPeripheral, didWriteValueFor characteristic: CBCharacteristic, error: Error?) {
        guard peripheral === selected else { return }
        awaitingWrite = false
        if let error { log.add("Write failed: \(error.localizedDescription)"); recoverConnection(error.localizedDescription); return }
        if let ack = lastAck, !ack.resent || Date().timeIntervalSince(ack.sentAt) < 10 { log.add("Write confirmed (\(String(format: "%.0f", Date().timeIntervalSince(ack.sentAt) * 1000)) ms after ACK handed over)") }
        drainWrites()
    }
    func peripheral(_ peripheral: CBPeripheral, didUpdateNotificationStateFor characteristic: CBCharacteristic, error: Error?) {
        guard peripheral === selected else { return }
        if let error {
            if characteristic.uuid == hrMeasurement { traceLive("Live HR notification failed: " + error.localizedDescription) }
            else { recoverConnection(error.localizedDescription) }
            return
        }
        traceLive("Notify \(characteristic.uuid.uuidString.prefix(8)): \(characteristic.isNotifying)")
        if characteristic.isNotifying { readyNotifications.insert(characteristic.uuid) }
        else { readyNotifications.remove(characteristic.uuid) }
        let wasReady = ready
        ready = writer != nil && notifications.allSatisfy { readyNotifications.contains($0) }
        updateStreaming()
        if ready && !wasReady {
            reconnectDelay = 2
            connectionWatch?.cancel()
            otherAppLikely = false
            connectHint?.cancel()
            status = "Connected"
            if bandSetup == .connecting { saveConfirmedBand(peripheral) }
            requestBattery()
            checkClock()
            if !checkingClock { requestAutoSync(appActive ? .foreground : .reconnect) }
        }
    }
    private func receive(_ frame: [UInt8]) {
        if frame.first == 0x24 { lastReplyAt = Date() }
        if frame.first == 0x2b, frame.count >= 1000 { captureOptical(frame) }
        if frame.count >= 3, frame[0] == 0x24, [UInt8(3), 0x3f, 0x6b].contains(frame[2]) {
            traceLive("RX command response " + frame.map { String(format: "%02X", $0) }.joined())
        }
        if let type = frame.first, type == 0x28 || type == 0x2b {
            if liveSamples.isEmpty { traceLive("RX live \(frame.count) bytes " + frame.prefix(24).map { String(format: "%02X", $0) }.joined()) }
        }
        if let reading = HeartRateReading.proprietary(frame) {
            if liveSyncCheck == nil { recordLive(reading) }
            return
        }
        if let sequence = batterySequence, HistoryProtocol.matchesResponse(frame, command: .batteryLevel, sequence: sequence) {
            batterySequence = nil; batteryAsked = false
            if let percent = HistoryProtocol.batteryResponse(frame) { batteryPercent = percent; batteryDate = Date(); log.add(String(format: "Battery %.1f%%", percent)) }
            return
        }
        // Wrist and charging events. History replays old ones, so only a recent event changes what is shown.
        if let (event, date) = HistoryProtocol.event(frame), abs(date.timeIntervalSinceNow) < 300 {
            switch event {
            case .wristOn: onWrist = true
            case .wristOff: onWrist = false
            case .chargingOn: charging = true
            case .chargingOff: charging = false
            }
        }
        if checkingClock, HistoryProtocol.matchesResponse(frame, command: .getClock, sequence: clockSequence), let date = HistoryProtocol.clockResponse(frame) {
            handleClockReading(date); return
        }
        if repairingClock, HistoryProtocol.matchesResponse(frame, command: .getClock, sequence: clockSequence),
           let date = HistoryProtocol.clockResponse(frame) {
            repairingClock = false; clockTask?.cancel()
            if abs(date.timeIntervalSinceNow) <= 30 {
                clockStatus = "The band's time is set. Wear it for a few minutes, then sync."
                requestAutoSync(appActive ? .foreground : .reconnect)
            } else {
                clockStatus = "Couldn't confirm the band's time. Try again in a moment."
                requestAutoSync(appActive ? .foreground : .reconnect)
            }
            return
        }
        guard syncing, !frame.isEmpty, let device = selected?.identifier.uuidString else { return }
        if [UInt8(0x2f), 0x31].contains(frame[0]) {
            lastProgress = Date()
            if let ack = lastAck {
                log.add(String(format: "Next frame %.1f s after ACK (type %02X)", Date().timeIntervalSince(ack.sentAt), frame[0]))
                lastAck = nil
            }
            armChunkWatch()
        }
        if let pendingCommand, frame.count >= 5, frame[0] == 0x24, frame[2] == pendingCommand.rawValue,
           !HistoryProtocol.matchesResponse(frame, command: pendingCommand, sequence: pendingSequence) {
            log.add(String(format: "Reply to %@ with sequence %02X, expected %02X (ignored)", "\(pendingCommand)", frame[3], pendingSequence ?? 0))
        }
        batch.append(frame)
        if frame[0] == 0x2f {
            if liveSyncCheck?.firstHistoryAt == nil {
                liveSyncCheck?.firstHistoryAt = ProcessInfo.processInfo.systemUptime
            }
            syncRecords += 1
            if HistoryProtocol.sample(frame, device: device) == nil { rejectedRecords += 1 }
        }
        // Bound memory even if a firmware never supplies the expected batch marker.
        if batch.count > 512 { fail("Unexpectedly large sync batch; stopped without acknowledging it"); return }
        do {
            guard let historyStore else { fail("History storage unavailable"); return }
            if let token = HistoryProtocol.token(frame) {
                let started = Date()
                let records = batch.filter { $0.first == 0x2f }.count
                let newest = batch.compactMap { HistoryProtocol.sample($0, device: device)?.date }.max()
                try historyStore.persist(batch, device: device, cursor: token); batch = []
                liveSyncCheck?.committedRecords += records
                chunkCount += 1; recordsSeen += records
                let cursor = token.map { String(format: "%02X", $0) }.joined()
                log.add("Chunk \(chunkCount): \(records) records, cursor \(cursor), saved in \(Int(Date().timeIntervalSince(started) * 1000)) ms")
                if records > 0 { noProgressRestarts = 0 } else if token == lastEndCursor { noProgressRestarts += 1 }
                lastEndCursor = token
                if let newest {
                    let behind = max(0, Int(Date().timeIntervalSince(newest) / 60))
                    status = "Synced up to \(newest.formatted(date: .omitted, time: .shortened)) · \(behind) min behind, continuing"
                }
                sendAcknowledge(token)
            } else if HistoryProtocol.complete(frame) {
                let finalRecords = batch.filter { $0.first == 0x2f }.count
                try historyStore.persist(batch, device: device); batch = []
                liveSyncCheck?.committedRecords += finalRecords
                finishLiveSyncCheck("Sync completed.")
                samples = try historyStore.recent(); syncing = false; timeout?.cancel()
                autoSyncFailures = 0; ackWatch?.cancel(); lastAck = nil; log.add("Sync complete · \(syncRecords) records in \(chunkCount) chunks")
                lastSync = Date(); UserDefaults.standard.set(lastSync, forKey: "lastSync"); status = syncRecords == 0 ? "Sync complete · no history records received" : "Sync complete · \(syncRecords) records, \(rejectedRecords) without decoded HR"
                savedDiagnostics = try historyStore.diagnostics()
                pendingCommand = nil
                updateStreaming()
                onHistoryChanged?()
                try? historyStore.pruneOptical(before: Date().addingTimeInterval(-14 * 86400))
                requestBattery()
                maybeSpotCheck()
            } else if let pendingCommand, HistoryProtocol.matchesResponse(frame, command: pendingCommand, sequence: pendingSequence) {
                // Result 2 is pending, not a completed command. Keep the request open.
                lastProgress = Date()
                if frame[4] == 2 { return }
                guard frame[4] == 1 else { log.add("Band refused \(pendingCommand) (\(frame[4]))"); fail("Band refused \(pendingCommand) (result \(frame[4])). Saved data is retained."); return }
                self.pendingCommand = nil; pendingSequence = nil
                switch pendingCommand {
                case .hello: send(.name)
                case .name: send(.range)
                case .range: send(.alarm)
                case .alarm: handshakeDone = true; status = "Downloading history…"; send(.history)
                default: break
                }
            }
        } catch { log.add("Could not save history: \(error.localizedDescription)"); fail("We couldn't save your band's data. Sync again in a moment.") }
    }
    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        guard peripheral === selected else { return }
        setupConnectTask?.cancel()
        log.add("Connected")
        watchConnection(peripheral)
        status = "Discovering services…"; peripheral.discoverServices([service, hrService])
    }
    func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        if finishRetirement(peripheral) { return }
        guard peripheral === selected else { return }
        recoverConnection(error?.localizedDescription ?? "Couldn't connect to the band.")
    }

    func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        if finishRetirement(peripheral) { return }
        guard peripheral === selected else { return }
        recoverConnection(error?.localizedDescription ?? "The band disconnected.")
    }

    private func watchConnection(_ peripheral: CBPeripheral) {
        connectionWatch?.cancel()
        connectionWatch = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(20)) } catch { return }
            guard let self, self.selected === peripheral, !self.ready else { return }
            self.recoverConnection("The band didn't finish connecting.")
        }
    }

    private func recoverConnection(_ message: String) {
        log.add("Connection ended: " + message)
        if bandSetup == .connecting {
            bandSetup = .help("Couldn't finish setup. Keep the band close and try again.")
        }
        retireConnection()
        if retiringPeripheral == nil { scheduleReconnect() }
    }

    private func scheduleReconnect(waitingForRange: Bool = false) {
        guard savedBandID != nil, !bandSetup.ownsConnection, retiringPeripheral == nil else { return }
        status = waitingForRange ? "Band out of reach" : "Reconnecting to your band…"
        let delay = reconnectDelay
        reconnectDelay = min(delay * 2, 60)
        reconnectTask?.cancel()
        reconnectTask = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(delay)) } catch { return }
            self?.reconnectSavedBand()
        }
    }

    func centralManager(_ central: CBCentralManager, willRestoreState dict: [String: Any]) {
        let peripherals = dict[CBCentralManagerRestoredStatePeripheralsKey] as? [CBPeripheral] ?? []
        let saved = peripherals.first { $0.identifier == savedBandID }
        for peripheral in peripherals where peripheral !== saved {
            central.cancelPeripheralConnection(peripheral)
        }
        guard let saved, !bandSetup.ownsConnection else { return }
        selected = saved
        saved.delegate = self
        status = "Restoring connection"
        if saved.state == .connected {
            centralManager(central, didConnect: saved)
        } else if saved.state != .connecting {
            selected = nil
        }
    }
    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        guard peripheral === selected else { return }
        if let error { recoverConnection(error.localizedDescription); return }
        guard peripheral.services?.contains(where: { $0.uuid == service }) == true else { recoverConnection("WHOOP service unavailable"); return }
        for service in peripheral.services ?? [] { peripheral.discoverCharacteristics(nil, for: service) }
    }
    func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        guard peripheral === selected else { return }
        if let error { recoverConnection(error.localizedDescription); return }
        if service.uuid == hrService {
            hrCharacteristic = service.characteristics?.first { $0.uuid == hrMeasurement }
            liveMessage = hrCharacteristic == nil ? "Live HR unavailable on this service" : "Waiting for live reading"
            updateStreaming(); return
        }
        guard service.uuid == self.service else { return }
        status = "Connected"
        writer = service.characteristics?.first { $0.uuid == CBUUID(string: "61080002-8d6d-82b8-614a-1c8cb0f8dcc6") && ($0.properties.contains(.write) || $0.properties.contains(.writeWithoutResponse)) }
        for characteristic in service.characteristics ?? [] where notifications.contains(characteristic.uuid) && characteristic.properties.contains(.notify) {
            peripheral.setNotifyValue(true, for: characteristic)
        }
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        guard peripheral === selected, ready else { return }
        if let error { fail("We couldn't reach your band. Try again.", error); return }
        guard let data = characteristic.value else { return }
        if characteristic.uuid == hrMeasurement {
            if let reading = HeartRateReading.parse(Array(data)) {
                countLiveSyncReading()
                recordLive(reading)
            }
            return
        }
        lastFrameAt = Date()
        var decoder = decoders[characteristic.uuid] ?? FrameDecoder()
        let frames = decoder.append(Array(data)); decoders[characteristic.uuid] = decoder
        packetCount += frames.count
        for frame in frames { receive(frame) }
    }
}

import os

/// Connection events kept across launches (last 1,000 lines), so a drop can be explained after the fact.
/// Also written to the unified log (subsystem personal.whooptracker, category ble).
@MainActor final class BLELog: ObservableObject {
    @Published private(set) var lines: [String] = []
    private let logger = Logger(subsystem: "personal.whooptracker", category: "ble")
    private let url = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("ble-log.txt")
    private static let limit = 1000

    init() {
        if let text = try? String(contentsOf: url, encoding: .utf8) { lines = text.split(separator: "\n").map(String.init).suffix(Self.limit) }
    }

    func add(_ event: String) {
        logger.log("\(event, privacy: .public)")
        lines.append(Date().formatted(.dateTime.month(.abbreviated).day().hour().minute().second()) + "  " + event)
        if lines.count > Self.limit { lines.removeFirst(lines.count - Self.limit) }
        try? lines.joined(separator: "\n").write(to: url, atomically: true, encoding: .utf8)
    }

    func clear() { lines = []; try? FileManager.default.removeItem(at: url) }
    var text: String { lines.isEmpty ? "No connection events yet" : lines.joined(separator: "\n") }
}
