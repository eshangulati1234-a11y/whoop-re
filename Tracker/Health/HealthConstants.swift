import Foundation

enum HealthConstants {
    // Minute bins preserve missing data rather than interpolating sensor gaps.
    static let minuteSeconds: TimeInterval = 60
    // Keep optional HRV unavailable until enough actual RR intervals exist.
    static let minimumRRIntervals = 20
    // Edwards load-to-score mapping specified in the functionality plan; experimental.
    static let strainScale = 200.0
    // UI computation throttle, not a Bluetooth polling timer.
    static let liveRecomputeSeconds: TimeInterval = 30

    // MARK: Workout detection
    // A minute counts as "working" at or above this share of max HR (zone 2 floor).
    static let detectionThreshold = 0.60
    // Start when at least this many of the last `detectionStartWindow` minutes are working.
    static let detectionStartHits = 5
    static let detectionStartWindow = 6
    // End after this many measured minutes below the threshold in a row...
    static let detectionEndBelowMinutes = 5
    // ...or after this many minutes without reaching it at all (covers data gaps).
    static let detectionEndGapMinutes = 10
    // Shorter efforts (stairs, a dash for the bus) are not workouts.
    static let detectionMinimumMinutes = 10
    // A detection overlapping a saved workout by more than this share is suppressed.
    static let detectionOverlapShare = 0.5
    // History-found detections and sleeps older than this are stored but not notified.
    static let notificationRecency: TimeInterval = 12 * 3600

    // MARK: Sleep
    // Search window for the night ending on day D: 18:00 on D−1 to 14:00 on D.
    static let sleepWindowStartHour = 18
    static let sleepWindowEndHour = 14
    // Asleep when the rolling median sits this far below the daytime baseline.
    static let sleepDropBPM = 10.0
    static let sleepRollingMinutes = 10
    // Asleep also needs the rolling median movement at or under this (milli-g); sustained movement ends sleep.
    static let sleepStillMotion = 40.0
    // The quiet-wake baseline uses still minutes from 08:00 to this hour the day before.
    static let quietBaselineEndHour = 21
    static let quietBaselineMinutes = 60
    // The drop (or rise) must hold this long to count as onset (or wake).
    static let sleepHoldMinutes = 20
    // Awake stretches shorter than this inside a night are awakenings, not the end of sleep.
    static let sleepMergeGapMinutes = 60
    // Anything shorter is a nap and is not reported as the night's sleep.
    static let sleepMinimumMinutes = 120
    // Naps: a separate period 08:00-20:00 with this much sleep. Under napDirectMinutes needs the user's OK.
    static let napMinimumMinutes = 30
    static let napDirectMinutes = 60
    static let napMaximumMinutes = 180
    static let napHoldMinutes = 10
    static let napStartHour = 8
    static let napEndHour = 20
    // A nap needs measured stillness on fixed limits, not limits relative to the nap itself:
    // most minutes at or under napStillMotion, no run of napMoveRunMinutes over napMoveMotion,
    // and heart rate at least napDropBPM below the 45 minutes before it.
    static let napStillMotion = 30.0
    static let napStillShare = 0.8
    static let napMoveMotion = 100.0
    static let napMoveRunMinutes = 3
    static let napDropBPM = 8.0
    static let napLeadMinutes = 45
    // Resting heart rate ignores a minute more than 25% below the median of the half hour around it
    // (the band briefly reading half the real rate, or a loose fit).
    static let restingGlitchShare = 0.75
    static let restingGlitchRadius = 15
    // A nap shortens that night's sleep need, by at most this much.
    static let napNeedCap: TimeInterval = 90 * 60
    // A moving minute: gravity change over this multiple of the night's median and at least the floor (milli-g).
    // Untuned: no overnight data had been recorded when this was written.
    static let motionMultiple = 4.0
    static let motionFloor = 20.0
    /// Mean gravity change per minute (milli-g) at or below which the wearer counts as still for optical spot checks.
    static let stillMotion = 40.0
    // An awakening is this many minutes in a row this far above the sleeping median.
    static let awakeBoutMinutes = 3
    static let awakeRiseBPM = 15.0
    // Stage hypotheses need most of the night measured.
    static let stageMinimumCoverage = 0.8
    static let stageMinimumMinutes = 5
    static let sleepNeedBaselineHours = 7.5
    // Extra need per point of the previous day's strain.
    static let sleepNeedStrainMinutes = 3.0
    // Share of the last nights' shortfall carried as debt, and its cap.
    static let sleepDebtShare = 0.5
    static let sleepDebtNights = 3
    static let sleepDebtCap: TimeInterval = 2 * 3600
    static let consistencyNights = 4
    // Average deviation (minutes) that maps to a consistency of zero.
    static let consistencyZeroMinutes = 120.0

    // MARK: Recovery
    // Nights of baseline needed before a score is shown, and the rolling window.
    // Four completed valid nights unlock Recovery (WHOOP greys it out for the first four days); "Early" until 14.
    static let recoveryMinimumNights = 4
    static let recoveryEarlyNights = 14
    // A baseline lapses after this long without a valid night. Missed nights pause progress, never reset it.
    static let baselineLapseDays = 14
    static let validNightMinimumSeconds: TimeInterval = 4 * 3600
    static let validNightCoverage = 0.8
    // Weights are our choice: WHOOP says HRV carries most of the signal, resting HR and sleep add context.
    static let recoveryWeightHRV = 0.60, recoveryWeightRHR = 0.25, recoveryWeightSleep = 0.15
    // Without HRV: the previous fallback.
    static let recoveryFallbackRHR = 0.7, recoveryFallbackSleep = 0.3
    // Heart-rate-reserve zone floors (WHOOP's published method): zone 1 starts at 40% of reserve.
    static let zoneFloors = [0.4, 0.6, 0.7, 0.8, 0.9]
    // Used until four nights give a measured resting heart rate; strain is then labelled provisional.
    static let defaultRestingHR = 70.0
    // Energy model: flex heart rate at this share of heart-rate reserve; VO2max kept in this range (ml/kg/min).
    static let flexReserveShare = 0.15
    // Awake, still heart rate assumed this far above the overnight resting rate until it is measured.
    static let awakeRestingOffset = 15.0
    // Everyday movement counts only at or above this wrist movement (milli-g); walking measured ~400.
    static let energyMoveMotion = 150.0
    static let vo2maxRange = 25.0...70.0
    // Zone boundaries follow resting HR by at most 2 bpm a week (applied per new night).
    static let zoneDriftPerNight = 2.0 / 7
    static let zoneRestingNights = 14
    static let recoveryBaselineNights = 28
    static let recoveryCentre = 0.58
    static let recoveryGreen = 67
    static let recoveryYellow = 34
    // Floors stop a very stable baseline from turning tiny changes into huge z-scores.
    static let recoveryRHRFloor = 2.0
    static let recoveryHRVFloor = 5.0
    static let recoverySleepFloor = 0.05

    // MARK: Sync policy
    static let foregroundSyncAge: TimeInterval = 15 * 60
    static let backgroundSyncAge: TimeInterval = 30 * 60
    // Repeated triggers inside this window collapse into one attempt.
    static let syncCoalesce: TimeInterval = 15
    static let backgroundSyncBudget: TimeInterval = 20
}
