import Foundation

/// Experimental 0–100 readiness estimate from last night compared with a personal rolling baseline.
enum RecoveryEngine {
    struct Night: Equatable {
        /// Lowest 5-minute sleeping heart rate.
        var restingHR: Double
        var rmssd: Double?
        /// 0...1
        var sleepPerformance: Double?
    }

    /// - Parameters:
    ///   - tonight: the night being scored.
    ///   - baseline: earlier nights, oldest first. Only the most recent window is used.
    static func score(tonight: Night, baseline history: [Night]) -> RecoveryState {
        let nights = Array(history.suffix(HealthConstants.recoveryBaselineNights))
        guard nights.count >= HealthConstants.recoveryMinimumNights else { return .calibrating(nights: nights.count) }
        func z(_ value: Double, _ values: [Double], floor: Double) -> Double? {
            guard let mean = Stats.mean(values), let deviation = Stats.deviation(values) else { return nil }
            return (value - mean) / max(deviation, floor)
        }
        guard let rhr = z(tonight.restingHR, nights.map(\.restingHR), floor: HealthConstants.recoveryRHRFloor) else {
            return .calibrating(nights: nights.count)
        }
        let hrvHistory = nights.compactMap(\.rmssd)
        let hrv = tonight.rmssd.flatMap { hrvHistory.count >= HealthConstants.recoveryMinimumNights ? z($0, hrvHistory, floor: HealthConstants.recoveryHRVFloor) : nil }
        let sleepHistory = nights.compactMap(\.sleepPerformance)
        let sleep = tonight.sleepPerformance.flatMap { sleepHistory.count >= HealthConstants.recoveryMinimumNights ? z($0, sleepHistory, floor: HealthConstants.recoverySleepFloor) : nil } ?? 0

        // A lower resting heart rate than usual is good, so its z-score is inverted.
        let composite = hrv.map { HealthConstants.recoveryWeightHRV * $0 + HealthConstants.recoveryWeightRHR * -rhr + HealthConstants.recoveryWeightSleep * sleep }
            ?? (HealthConstants.recoveryFallbackRHR * -rhr + HealthConstants.recoveryFallbackSleep * sleep)
        let centre = HealthConstants.recoveryCentre
        let value = 100 / (1 + exp(-(composite + log(centre / (1 - centre)))))
        let score = min(100, max(0, Int(value.rounded())))
        let band: RecoveryBandKind = score >= HealthConstants.recoveryGreen ? .green : score >= HealthConstants.recoveryYellow ? .yellow : .red
        return .ready(RecoveryResult(score: score, band: band, usedHRV: hrv != nil, early: nights.count < HealthConstants.recoveryEarlyNights))
    }
}
