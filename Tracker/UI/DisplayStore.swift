import SwiftUI
import Combine
import CoreBluetooth

/// The seam between the screens and whatever computes health data.
///
/// - Live heart rate and the in-memory trace come from `BandManager` (attached once).
/// - Everything else (`day`, `lastSleep`, `detections`, workout metrics) is optional and
///   stays empty until the health engine publishes it. Views render designed empty states.
@MainActor final class DisplayStore: ObservableObject {
    @Published var day = DisplayDay()
    @Published var lastSleep: DisplaySleep?
    @Published var detections: [DisplayDetection] = []
    @Published var calibration = DisplayCalibration()
    @Published var naps: [DisplayNap] = []
    var decideNap: ((String, Bool) -> Void)?
    @Published var workoutMetrics: [UUID: DisplayWorkoutMetrics] = [:]
    /// Live calories / strain for the running workout.
    @Published var activeMetrics: DisplayWorkoutMetrics?
    /// Steps counted by the iPhone today. `nil` when unavailable or not allowed.
    @Published var stepsToday: Int?
    let steps = StepService()

    @Published private(set) var current: LiveReading?
    /// Rolling in-memory live trace, thinned to one point per 5 s, kept for 30 minutes.
    @Published private(set) var trace: [HRPoint] = []

    /// Hooks for the health engine. `nil` until it is wired in.
    var confirmDetection: ((DisplayDetection, String) -> Void)?
    var dismissDetection: ((DisplayDetection) -> Void)?
    var loadDay: ((Date) -> DisplayDaySummary)?

    private(set) weak var band: BandManager?
    private var bandLink: AnyCancellable?
    var previewMode = false
    var previewTimer: Timer?

    static let traceWindow: TimeInterval = 30 * 60
    static let traceStep: TimeInterval = 5

    func attach(_ band: BandManager) {
        guard self.band == nil else { return }
        self.band = band
        steps.onToday = { [weak self] count in self?.stepsToday = count }
        steps.start()
        bandLink = band.$liveSamples.sink { [weak self] samples in
            guard let latest = samples.last else { self?.current = nil; return }
            self?.ingest(bpm: latest.bpm, at: latest.date)
        }
        #if DEBUG
        if CommandLine.arguments.contains("-previewData") { PreviewData.apply(to: self, band: band) }
        #endif
    }

    func ingest(bpm: Int, at date: Date) {
        current = LiveReading(bpm: bpm, date: date)
        if let last = trace.last, date.timeIntervalSince(last.date) < Self.traceStep { return }
        trace.append(HRPoint(date: date, bpm: bpm))
        let cutoff = date.addingTimeInterval(-Self.traceWindow)
        if let first = trace.first, first.date < cutoff { trace.removeAll { $0.date < cutoff } }
    }

    func seedTrace(_ points: [HRPoint]) { trace = points }

    func linkState(at now: Date = Date()) -> LinkState {
        if previewMode { return .live }
        guard let band else { return .noBand }
        if band.status.hasPrefix("Bluetooth") { return .bluetoothOff }
        if let peripheral = band.selected, peripheral.state == .connected {
            if let current, now.timeIntervalSince(current.date) <= 10 { return .live }
            if band.syncing && band.activeWorkout == nil { return .syncing }
            return .stale(secondsAgo: current.map { Int(now.timeIntervalSince($0.date)) })
        }
        let status = band.status
        if band.selected != nil || status.hasPrefix("Connecting") || status.hasPrefix("Restoring")
            || status.hasPrefix("Searching") || status.hasPrefix("Discovering") || status.localizedCaseInsensitiveContains("reconnecting") {
            return .connecting
        }
        return .noBand
    }

    /// Heart-rate points recorded today from synced history.
    func historyToday(_ band: BandManager) -> [HRPoint] {
        let start = Calendar.current.startOfDay(for: Date())
        return band.samples.filter { $0.date >= start }.map(\.point)
    }
}
