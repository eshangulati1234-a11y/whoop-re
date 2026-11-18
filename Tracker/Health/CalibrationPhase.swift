import Foundation

/// One model of "where is the user in setup and calibration", shown the same way on every screen.
enum CalibrationPhase: Equatable {
    case setup
    case calibrating(validNights: Int)
    case early(validNights: Int)
    case calibrated

    static func make(validNights: Int, setupComplete: Bool) -> CalibrationPhase {
        guard setupComplete else { return .setup }
        if validNights < HealthConstants.recoveryMinimumNights { return .calibrating(validNights: validNights) }
        if validNights < HealthConstants.recoveryEarlyNights { return .early(validNights: validNights) }
        return .calibrated
    }
    var recoveryAvailable: Bool {
        switch self { case .setup, .calibrating: false; case .early, .calibrated: true }
    }
}

enum NightMissReason: String, Equatable {
    case tooShort = "Asleep for under 4 hours"
    case gaps = "The band wasn't worn for over 20% of the night"
    case excluded = "You excluded this day"
    case noSleep = "No sleep was detected"
}

enum NightVerdict: Equatable {
    case counted
    case missed(NightMissReason)
    var counts: Bool { self == .counted }
}

struct NightLog: Identifiable, Equatable {
    var wakeDay: Int
    var verdict: NightVerdict
    var id: Int { wakeDay }
}

enum CalibrationNights {
    /// A night counts when it has at least 4 h asleep and 80% of the night measured.
    static func verdict(_ session: SleepSession?, excluded: Bool) -> NightVerdict {
        guard let session, session.isNap != true else { return .missed(.noSleep) }
        if excluded { return .missed(.excluded) }
        if session.coverage < HealthConstants.validNightCoverage { return .missed(.gaps) }
        if session.asleep * session.coverage < HealthConstants.validNightMinimumSeconds { return .missed(.tooShort) }
        return .counted
    }
    /// The last 14 days as night dots, oldest first. `sessions` is keyed by wake day.
    static func log(sessions: [Int: SleepSession], excludedDays: Set<Int>, today: Int, days: Int = 14) -> [NightLog] {
        ((today - days + 1)...today).map { day in NightLog(wakeDay: day, verdict: verdict(sessions[day], excluded: excludedDays.contains(day))) }
    }
    /// Valid nights inside the 28-night window. Missed nights pause the count; it lapses to zero only when the
    /// newest valid night is more than 14 days old.
    static func validCount(sessions: [Int: SleepSession], excludedDays: Set<Int>, today: Int) -> Int {
        let valid = sessions.filter { $0.key > today - HealthConstants.recoveryBaselineNights && $0.key <= today && verdict($0.value, excluded: excludedDays.contains($0.key)).counts }.keys
        guard let newest = valid.max(), today - newest <= HealthConstants.baselineLapseDays else { return 0 }
        return valid.count
    }
}

/// Setup steps shown as a checklist on Home until all are done.
enum SetupStep: String, CaseIterable, Identifiable {
    case profile = "Tell us about you"
    case band = "Connect your band"
    case wear = "Wear it to sleep"
    var id: String { rawValue }
    var detail: String {
        switch self {
        case .profile: "Sets your calories and heart-rate zones"
        case .band: "Keep the band close to your phone"
        case .wear: "One night of sleep starts the learning. Recovery appears after four"
        }
    }
}

/// The band's clock check and first sync happen automatically, so they are not steps the user sees.
struct SetupState: Equatable {
    var profileComplete = false
    var bandPaired = false
    var wornLastNight = false
    var remaining: [SetupStep] {
        var steps: [SetupStep] = []
        if !profileComplete { steps.append(.profile) }
        if !bandPaired { steps.append(.band) }
        if !wornLastNight { steps.append(.wear) }
        return steps
    }
    var isComplete: Bool { remaining.isEmpty }
    func isDone(_ step: SetupStep) -> Bool { !remaining.contains(step) }
}
