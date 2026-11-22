import SwiftUI

// Display-layer models: exactly what the screens render, all optional where the
// underlying measurement may not exist yet. The health engine fills these through
// `DisplayStore`; the UI never invents a value (see docs/frontend-integration.md).

enum RecoveryBand {
    case green, yellow, red
    var color: Color {
        switch self {
        case .green: Palette.green
        case .yellow: Palette.yellow
        case .red: Palette.red
        }
    }
    var word: String {
        switch self {
        case .green: "Primed"
        case .yellow: "Steady"
        case .red: "Rest up"
        }
    }
}

struct DisplayRecovery {
    var score: Int
    var band: RecoveryBand
}

struct DisplayCalorieSource: Identifiable {
    var id: String
    var name: String
    var kcal: Double
    var isResting: Bool = false
    /// Secondary line, such as "Started by you · 6:10–6:55 PM".
    var detail: String? = nil
    var symbol: String? = nil
}

struct DisplayCalories {
    var resting: Double
    var active: Double
    var goal: Double?
    /// 24 slots, midnight first. `nil` = hour has not happened yet.
    var hourly: [Double?]
    var sources: [DisplayCalorieSource]
    var total: Double { resting + active }
}

struct DisplayDay {
    var calibrationMessage = "Learning your baseline"
    var loadContext: String?
    /// 0...21
    var strain: Double?
    var recovery: DisplayRecovery?
    /// Set while the recovery baseline is still being learned (fewer than the needed nights).
    var recoveryCalibratingNights: Int?
    /// 0...1
    var sleepPerformance: Double?
    var calories: DisplayCalories?
    /// Strain is shown from day one; this says zones still use the placeholder resting heart rate.
    var strainProvisional = false
    var recoveryEarly = false
}

/// What the screens need to explain setup and calibration, from one model.
struct DisplayCalibration {
    var phase: CalibrationPhase = .setup
    var setup = SetupState()
    var nights: [NightLog] = []
    var validNights = 0
    var restingHR: Double?
    var restingNights = 0
    var hrvNights = 0
    var zonesProvisional = true
    var skinState: String?
    /// Plain words for the most recent night, or nil before any sleep.
    var lastNight: String?
}

struct DisplayNap: Identifiable {
    var id: String
    var start: Date
    var end: Date
    var asleep: TimeInterval
    var needsReview: Bool
}

enum SleepStage: CaseIterable {
    case awake, rem, light, deep
    var color: Color {
        switch self {
        case .awake: Palette.awake
        case .rem: Palette.rem
        case .light: Palette.sleep
        case .deep: Palette.deep
        }
    }
    var title: String {
        switch self {
        case .awake: "Awake"
        case .rem: "REM"
        case .light: "Light"
        case .deep: "Deep"
        }
    }
    /// Row in the hypnogram, top to bottom.
    var row: Int {
        switch self {
        case .awake: 0
        case .rem: 1
        case .light: 2
        case .deep: 3
        }
    }
}

struct DisplaySleepSegment: Identifiable {
    var id = UUID()
    var stage: SleepStage
    var start: Date
    var end: Date
    var duration: TimeInterval { end.timeIntervalSince(start) }
}

struct DisplaySleep {
    var start: Date
    var end: Date
    var asleep: TimeInterval
    var inBed: TimeInterval
    var need: TimeInterval
    /// 0...1
    var performance: Double
    var efficiency: Double?
    var consistency: Double?
    /// `nil` when coverage was too low to estimate stages.
    var segments: [DisplaySleepSegment]?
    var sleepingHR: Int?
    var hrv: Double?
    var respiratoryRate: Double?
    var needBaseline: TimeInterval?
    var needStrain: TimeInterval?
    var needDebt: TimeInterval?
    var needNap: TimeInterval?
    var disturbances: Int?
    var cycles: Int?
    var restorative: Double?
    var skinState: String?

    func total(for stage: SleepStage) -> TimeInterval {
        (segments ?? []).filter { $0.stage == stage }.reduce(0) { $0 + $1.duration }
    }
}

struct DisplayWorkoutMetrics {
    var calories: Double?
    var strain: Double?
}

struct DisplayDetection: Identifiable {
    var id: String
    var start: Date
    var end: Date
    var guessedType: String
    var confidence: Double
    var avgHR: Int
    var maxHR: Int
    var calories: Double?
    var strain: Double?
    var trace: [HRPoint]
    var zones: [ZoneBand: TimeInterval]
    var duration: TimeInterval { end.timeIntervalSince(start) }
}

struct LiveReading: Equatable {
    var bpm: Int
    var date: Date
}

enum LinkState: Equatable {
    case live
    case stale(secondsAgo: Int?)
    /// Connected and downloading history; the live stream is paused on purpose.
    case syncing
    case connecting
    case noBand
    case bluetoothOff

    var title: String {
        switch self {
        case .live: "Live"
        case .stale: "No signal"
        case .syncing: "Syncing"
        case .connecting: "Connecting"
        case .noBand: "No band"
        case .bluetoothOff: "Bluetooth off"
        }
    }
    var color: Color {
        switch self {
        case .live: Palette.green
        case .stale, .connecting: Palette.calories
        case .syncing: Palette.strain
        case .noBand: Palette.muted
        case .bluetoothOff: Palette.red
        }
    }
    var isLive: Bool { self == .live }
    /// One plain-language line for subtitles.
    var detail: String {
        switch self {
        case .live:
            return "Band connected · Heart rate streaming"
        case .stale(let seconds):
            if let seconds { return "Last reading \(seconds) s ago · Looking for your band" }
            return "Waiting for your band"
        case .syncing:
            return "Downloading history · live heart rate resumes after"
        case .connecting:
            return "Connecting to your band…"
        case .noBand:
            return "No band connected"
        case .bluetoothOff:
            return "Turn on Bluetooth in Settings"
        }
    }
}

/// Activity types shared by the start screen, rows and summaries.
enum ActivityKind: String, CaseIterable, Identifiable {
    case running = "Running"
    case cycling = "Cycling"
    case walking = "Walking"
    case strength = "Strength"
    case other = "Other"

    var id: String { rawValue }
    /// SF Symbol.
    var symbol: String {
        switch self {
        case .running: "figure.run"
        case .cycling: "figure.outdoor.cycle"
        case .walking: "figure.walk"
        case .strength: "dumbbell.fill"
        case .other: "figure.mixed.cardio"
        }
    }
    static func symbol(for type: String) -> String {
        (ActivityKind(rawValue: type) ?? .other).symbol
    }
}


/// A past day, rebuilt from stored heart-rate history for the Home day picker.
struct DisplayDaySummary {
    var date: Date
    var strain: Double?
    var calories: Double?
    var activeCalories: Double?
    var asleep: TimeInterval?
    var sleepPerformance: Double?
    var hasHeartRate: Bool
    var workouts: [Workout]
    var sleep: DisplaySleep?
}
