import Foundation

// Pure value types shared by the engines, the store and the app. Every number here is an
// estimate derived from heart rate only; nothing is filled in when the inputs are missing.

enum WorkoutSource: String, Codable { case manual, detected }

struct WorkoutMetrics: Codable, Equatable {
    var avgHR: Int?
    var maxHR: Int?
    /// Seconds per zone 1...5.
    var zoneSeconds: [Int: Double] = [:]
    /// 0...21, `nil` without a valid profile.
    var strain: Double?
    /// Total kcal (resting + active) for the window, `nil` without a valid profile.
    var calories: Double?
}

enum SleepStageKind: String, Codable, CaseIterable { case awake, rem, light, deep }

struct SleepSegment: Codable, Equatable {
    var stage: SleepStageKind
    var start: Date
    var end: Date
}

struct SleepSession: Codable, Equatable {
    var start: Date
    var end: Date
    var inBed: TimeInterval
    var asleep: TimeInterval
    var awake: TimeInterval
    /// HR-only stage hypothesis. `nil` when coverage was too low.
    var stages: [SleepSegment]?
    var sleepingHR: Double
    /// Lowest 5-minute average while asleep.
    var lowestHR: Double
    var rmssd: Double?
    /// Share of minutes in the window that had data, 0...1.
    var coverage: Double
    var need: TimeInterval?
    var needBaseline: TimeInterval?
    var needStrain: TimeInterval?
    var needDebt: TimeInterval?
    /// 0...1
    var performance: Double?
    /// 0...100
    var consistency: Double?
    // Added with motion data; all optional so stored sessions still decode.
    var disturbances: Int?
    var cycles: Int?
    /// (deep + REM) / asleep, 0...1. Estimated from stages.
    var restorativeShare: Double?
    /// Median raw skin-temperature ADC value while asleep. Never shown as degrees.
    var skinRaw: Double?
    var isNap: Bool?
    var needNap: TimeInterval?
    /// Minutes with no usable data inside the period.
    var noData: TimeInterval?
}

struct DetectedActivity: Codable, Identifiable, Equatable {
    enum Status: String, Codable { case pending, confirmed, dismissed }
    var id: String
    var start: Date
    var end: Date
    var guessedType: String
    /// 0...1
    var confidence: Double
    var status: Status
    /// Still above the threshold when last evaluated.
    var isOpen: Bool = false
    var notified: Bool = false
    var metrics: WorkoutMetrics?
}

enum RecoveryBandKind: String, Codable { case green, yellow, red }

struct RecoveryResult: Codable, Equatable {
    var score: Int
    var band: RecoveryBandKind
    var usedHRV: Bool
    /// Fewer than 14 nights of baseline: the score is real but still settling.
    var early = false
}

enum RecoveryState: Equatable {
    case calibrating(nights: Int)
    case ready(RecoveryResult)
}

enum Stats {
    static func median(_ values: [Double]) -> Double? {
        guard !values.isEmpty else { return nil }
        let sorted = values.sorted(), mid = sorted.count / 2
        return sorted.count % 2 == 0 ? (sorted[mid - 1] + sorted[mid]) / 2 : sorted[mid]
    }
    /// Nearest-rank percentile, `p` in 0...1.
    static func percentile(_ values: [Double], _ p: Double) -> Double? {
        guard !values.isEmpty else { return nil }
        let sorted = values.sorted()
        return sorted[min(sorted.count - 1, max(0, Int((p * Double(sorted.count - 1)).rounded())))]
    }
    static func mean(_ values: [Double]) -> Double? { values.isEmpty ? nil : values.reduce(0, +) / Double(values.count) }
    static func deviation(_ values: [Double]) -> Double? {
        guard values.count >= 2, let mean = mean(values) else { return nil }
        return sqrt(values.map { pow($0 - mean, 2) }.reduce(0, +) / Double(values.count - 1))
    }
}
