import Foundation
import CoreMotion

/// Step counts from the iPhone's motion coprocessor. The band reports no steps, so this counts
/// whenever the phone is carried. The system keeps about a week of history, which is enough for the day view.
@MainActor final class StepService {
    private let pedometer = CMPedometer()
    private var live = false
    var onToday: ((Int?) -> Void)?

    static var isAvailable: Bool { CMPedometer.isStepCountingAvailable() }

    /// Refreshes today's total and keeps it updating while the app is open.
    func start() {
        guard Self.isAvailable, CMPedometer.authorizationStatus() != .denied, CMPedometer.authorizationStatus() != .restricted else { onToday?(nil); return }
        refresh()
        guard !live else { return }
        live = true
        pedometer.startUpdates(from: Calendar.current.startOfDay(for: Date())) { [weak self] data, _ in
            guard let count = data?.numberOfSteps.intValue else { return }
            Task { @MainActor in self?.onToday?(count) }
        }
    }

    func stop() { pedometer.stopUpdates(); live = false }

    func refresh() {
        let start = Calendar.current.startOfDay(for: Date())
        pedometer.queryPedometerData(from: start, to: Date()) { [weak self] data, _ in
            let count = data?.numberOfSteps.intValue
            Task { @MainActor in self?.onToday?(count) }
        }
    }

    /// Steps for a past day, or nil when the system no longer has them.
    func steps(on day: Date) async -> Int? {
        guard Self.isAvailable else { return nil }
        let start = Calendar.current.startOfDay(for: day)
        let end = Calendar.current.date(byAdding: .day, value: 1, to: start) ?? start.addingTimeInterval(86400)
        return await withCheckedContinuation { continuation in
            pedometer.queryPedometerData(from: start, to: end) { data, _ in continuation.resume(returning: data?.numberOfSteps.intValue) }
        }
    }
}
