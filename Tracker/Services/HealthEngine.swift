import SwiftUI
import Combine

/// Owns the health calculations and feeds the display layer. Bluetooth stays in `BandManager`;
/// this type only reads what it stored (SQLite, workouts) and what it forwards through hooks.
/// All estimates come from heart rate only and are `nil` whenever the inputs are missing.
@MainActor final class HealthEngine: ObservableObject {
    nonisolated static let profileKey = "userProfile"
    static let detectionEnabledKey = "detectionEnabled"

    let personalization = Personalization()
    private var lastRRDate: Date?
    private var rrContinuous = true
    @Published private(set) var profile: UserProfile?

    private weak var band: BandManager?
    private weak var display: DisplayStore?
    private var storage: HistoryStore? { band?.storage }
    private var calendar: Calendar { .current }

    private var bucket: (minute: Int64, values: [Int], rr: [Double])?
    private var lastToday = Date.distantPast
    private var lastActive = Date.distantPast
    private var sleepSession: (day: Int, session: SleepSession)?
    private var recovery: RecoveryState?
    private var metricsCache: [UUID: (WorkoutMetrics, active: Double?)] = [:]
    private var lastProfileData: Data?
    private var cancellables = Set<AnyCancellable>()
    private var midnightTask: Task<Void, Never>?

    /// Called whenever the running workout's numbers refresh (Live Activity). `nil` workout = none running.
    var onActiveWorkout: ((Workout?, DisplayWorkoutMetrics?, LiveReading?) -> Void)?
    /// Called when a workout ends, with its final metrics.
    var onWorkoutEnded: ((Workout, WorkoutMetrics) -> Void)?
    private let liveActivity = WorkoutActivityController()

    // MARK: Profile

    nonisolated static func loadProfile() -> UserProfile? {
        if let data = UserDefaults.standard.data(forKey: profileKey), let profile = try? JSONDecoder().decode(UserProfile.self, from: data), profile.validationError == nil {
            return profile
        }
        #if DEBUG
        if CommandLine.arguments.contains("-demoHistory") { return UserProfile(ageYears: 30, weightKg: 75, heightCm: 180, sex: .male) }
        #endif
        return nil
    }

    // MARK: Wiring

    func attach(band: BandManager, display: DisplayStore) {
        guard self.band == nil else { return }
        self.band = band; self.display = display
        personalization.attach(band.storage)
        personalization.revisionRequested = { [weak self] in self?.recomputeSleep() }
        personalization.changed = { [weak self] in self?.metricsCache = [:]; self?.recomputeToday(force: true); self?.publishActive(force: true); self?.publishDetections() }
        profile = Self.loadProfile(); lastProfileData = UserDefaults.standard.data(forKey: Self.profileKey)
        band.onLiveReading = { [weak self] reading, date in self?.ingestLive(reading, at: date) }
        band.onHistoryChanged = { [weak self] in self?.historyDidChange() }
        band.onWorkoutStarted = { [weak self] workout in self?.workoutStarted(workout) }
        band.onWorkoutEnded = { [weak self] workout in self?.workoutFinished(workout) }
        band.onWorkoutsEdited = { [weak self, weak band] in
            guard let self, let band else { return }
            self.personalization.refresh(workouts: band.workouts); self.personalization.changed?()
        }
        band.onWorkoutPaused = { [weak self] in self?.publishActive(force: true) }
        band.onAppActiveChanged = { [weak self] active in
            if active { self?.recomputeAll(); self?.scheduleMidnight() } else { self?.flushLive() }
        }
        display.confirmDetection = { [weak self] detection, type in self?.confirm(detectionID: detection.id, type: type) }
        display.loadDay = { [weak self] date in self?.daySummary(date) ?? DisplayDaySummary(date: date, hasHeartRate: false, workouts: []) }
        display.dismissDetection = { [weak self] detection in self?.dismiss(detectionID: detection.id) }
        NotificationService.shared.onAction = { [weak self] id, confirmed in
            if confirmed { self?.confirm(detectionID: id, type: nil) } else { self?.dismiss(detectionID: id) }
        }
        NotificationCenter.default.publisher(for: UserDefaults.didChangeNotification)
            .debounce(for: .seconds(0.5), scheduler: DispatchQueue.main)
            .sink { [weak self] _ in self?.defaultsChanged() }
            .store(in: &cancellables)
        onActiveWorkout = { [weak self] workout, metrics, reading in self?.liveActivity.update(workout: workout, metrics: metrics, reading: reading) }
        onWorkoutEnded = { [weak self] workout, metrics in self?.liveActivity.end(finalWorkout: workout, metrics: metrics) }
        WorkoutCommandBridge.handler = { [weak band] command in
            switch command { case .pause: band?.pauseWorkout(); case .end: band?.finishWorkout() }
        }
        liveActivity.endOrphans(activeWorkoutID: band.activeWorkout?.id)
        recomputeAll()
        scheduleMidnight()
    }

    private func defaultsChanged() {
        let data = UserDefaults.standard.data(forKey: Self.profileKey)
        guard data != lastProfileData else { return }
        lastProfileData = data
        profile = Self.loadProfile(); metricsCache = [:]
        recomputeAll()
    }

    private func scheduleMidnight() {
        midnightTask?.cancel()
        let next = calendar.nextDate(after: Date(), matching: DateComponents(hour: 0, minute: 0, second: 5), matchingPolicy: .nextTime) ?? Date().addingTimeInterval(3600)
        midnightTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(max(1, next.timeIntervalSinceNow)))
            guard !Task.isCancelled else { return }
            self?.recomputeAll(); self?.scheduleMidnight()
        }
    }

    // MARK: Live ingest

    private func ingestLive(_ reading: HeartRateReading, at date: Date) {
        let minute = Int64(floor(date.timeIntervalSince1970 / 60))
        if let current = bucket, current.minute != minute { flush(current) ; bucket = nil }
        if bucket == nil || bucket?.minute != minute { rrContinuous = true; lastRRDate = nil }
        if let lastRRDate, date.timeIntervalSince(lastRRDate) > 3 { rrContinuous = false }
        if !reading.rrMilliseconds.isEmpty { lastRRDate = date }
        var current = bucket ?? (minute, [], [])
        current.values.append(reading.bpm); current.rr += reading.rrMilliseconds
        bucket = current
        let now = Date()
        if band?.activeWorkout != nil, now.timeIntervalSince(lastActive) >= 5 { publishActive(force: false) }
        if now.timeIntervalSince(lastToday) >= HealthConstants.liveRecomputeSeconds { recomputeToday(); runDetection(window: 6 * 3600) }
    }

    private func flush(_ minute: (minute: Int64, values: [Int], rr: [Double])) {
        guard let aggregate = HRTimeline.aggregate(minute.minute, minute.values) else { return }
        var value = aggregate
        value.rmssd = rrContinuous ? HRTimeline.rmssd(minute.rr) : nil
        value.validRRCount = value.rmssd == nil ? nil : minute.rr.count
        do { try storage?.saveLiveMinute(value) } catch { band?.fail("We couldn't save a heart-rate reading.", error) }
    }

    /// Persist the minute in progress without ending it (app backgrounded, workout finished).
    func flushLive() { if let bucket { flush(bucket) } }

    // MARK: Hooks from the band

    private func historyDidChange() {
        metricsCache = [:]
        recomputeSleep()
        personalization.refresh(workouts: band?.workouts ?? [])
        recomputeToday(force: true)
        runDetection(window: 72 * 3600)
    }

    private func workoutStarted(_ workout: Workout) {
        flushLive(); publishActive(force: true)
    }

    private func workoutFinished(_ workout: Workout) {
        flushLive()
        metricsCache[workout.id] = nil
        let result = metrics(start: workout.start, end: workout.end ?? Date(), readings: workout.readings)
        metricsCache[workout.id] = result
        onActiveWorkout?(nil, nil, nil)
        display?.activeMetrics = nil
        recomputeToday(force: true)
        onWorkoutEnded?(workout, result.0)
        NotificationService.shared.postSaved(id: workout.id.uuidString, type: workout.type, minutes: Int((workout.elapsed(at: workout.end ?? Date()) / 60).rounded()),
                                             strain: result.0.strain, calories: result.0.calories)
    }

    // MARK: Series

    private func minuteSeries(from: Date, to: Date, extra: [WorkoutReading] = []) -> [MinuteHR?] {
        guard let band, to > from else { return [] }
        let history = (try? storage?.samples(from: from, to: to)) ?? []
        let live = (try? storage?.liveMinutes(from: from, to: to)) ?? []
        var readings = extra
        for workout in band.workouts + (band.activeWorkout.map { [$0] } ?? []) { readings += workout.readings }
        let details = (try? storage?.historyMinutes(from: from, to: to)) ?? [:]
        return HRTimeline.minuteSeries(history: history, live: live, workoutReadings: readings, details: details, from: from, to: to)
    }

    private func firstMinute(_ date: Date) -> Int64 { Int64(floor(date.timeIntervalSince1970 / 60)) }

    private func dayNumber(_ date: Date) -> Int {
        let start = calendar.startOfDay(for: date)
        return Int(((start.timeIntervalSince1970 + Double(calendar.timeZone.secondsFromGMT(for: start))) / 86400).rounded())
    }

    // MARK: Metrics

    /// Metrics for a window. Calories and strain stay `nil` until a valid profile exists.
    private func metrics(start: Date, end: Date, readings: [WorkoutReading]) -> (WorkoutMetrics, active: Double?) {
        let series = minuteSeries(from: start, to: max(end, start.addingTimeInterval(60)), extra: readings)
        var result = WorkoutMetrics()
        let known = series.compactMap { $0 }
        let samples = known.reduce(0) { $0 + $1.count }
        if samples > 0 {
            result.avgHR = Int((known.reduce(0.0) { $0 + $1.average * Double($1.count) } / Double(samples)).rounded())
            result.maxHR = known.map(\.maximum).max()
        }
        var active: Double?
        if let currentProfile = profile {
            let profile = personalization.frozenProfile(currentProfile,key: "workout-profile:\(start.timeIntervalSince1970)")
            let snapshot = personalization.frozenBaseline(key: "workout-baseline:\(start.timeIntervalSince1970)")
            let zones = CalibrationEngine.zones(profile: profile,baseline: snapshot)
            for minute in known { if let zone = zones.zone(minute.average) { result.zoneSeconds[zone,default: 0] += 60 } }
            result.strain = CalibrationEngine.score(series,zones: zones)
            let workouts = (band?.workouts ?? []) + (band?.activeWorkout.map { [$0] } ?? [])
            if let workout = workouts.first(where: { $0.start == start }), AdaptiveCalories.supported(workout.type) {
                let calories = AdaptiveCalories.estimate(series,from: start,to: end,profile: profile,zones: zones,weights: personalization.feedback.weights,workouts: [workout],excluded: [],awakeHR: awakeHR)
                result.calories = calories.resting + calories.active; active = calories.active
            }

        }
        if let profile, end < Date().addingTimeInterval(-2) {
            let baseline = personalization.frozenBaseline(key: "workout-baseline:\(start.timeIntervalSince1970)")
            personalization.saveResult(PersonalMetricResult(strain: result.strain,calories: result.calories,provenance: MetricProvenance(version: baseline.version,profile: personalization.profile(profile,at: start),zones: CalibrationEngine.zones(profile: profile,baseline: baseline),coverage: CalibrationEngine.coverage(series),baseline: baseline)),key: "workout:\(start.timeIntervalSince1970)")
        }
        return (result, active)
    }

    private func cachedMetrics(_ workout: Workout) -> (WorkoutMetrics, active: Double?) {
        if let cached = metricsCache[workout.id] { return cached }
        let value = metrics(start: workout.start, end: workout.end ?? Date(), readings: workout.readings)
        metricsCache[workout.id] = value
        return value
    }

    private func publishActive(force: Bool) {
        guard let band, let display else { return }
        let now = Date()
        guard force || now.timeIntervalSince(lastActive) >= 5 else { return }
        lastActive = now
        guard let workout = band.activeWorkout else { display.activeMetrics = nil; onActiveWorkout?(nil, nil, nil); return }
        let result = metrics(start: workout.start, end: now, readings: workout.readings)
        let shown = DisplayWorkoutMetrics(calories: result.0.calories, strain: result.0.strain)
        display.activeMetrics = shown
        onActiveWorkout?(workout, shown, display.current)
    }

    // MARK: Today

    func recomputeAll() {
        recomputeSleep()
        personalization.refresh(workouts: band?.workouts ?? [])
        recomputeToday(force: true)
        runDetection(window: 72 * 3600)
        publishActive(force: true)
    }

    func recomputeToday(force: Bool = false) {
        guard let band, let display else { return }
        let now = Date()
        if !force, now.timeIntervalSince(lastToday) < HealthConstants.liveRecomputeSeconds { return }
        lastToday = now
        let dayStart = calendar.startOfDay(for: now)
        var day = DisplayDay()

        if let profile {
            let series = minuteSeries(from: dayStart, to: now)
            let zones = personalization.zones(profile)
            // Today follows the live baseline, so Strain stops being provisional as soon as resting HR is measured.
            // Past days stay frozen with the zones they were first computed with.
            let dayBaseline = personalization.baseline
            let dayZones = CalibrationEngine.zones(profile: profile,baseline: dayBaseline)
            day.strain = CalibrationEngine.score(series,zones: dayZones)
            day.strainProvisional = dayZones.provisional
            day.calibrationMessage = personalization.progress
            day.loadContext = CalibrationEngine.context(series,days: personalization.days,zones: zones,now: now)
            let sleeps = ((try? storage?.sleeps(fromDay: dayNumber(now) - 1,toDay: dayNumber(now))) ?? []).map { DateInterval(start: $0.session.start,end: $0.session.end) }
            let total = AdaptiveCalories.estimate(series,from: dayStart,to: now,profile: profile,zones: zones,weights: personalization.feedback.weights,workouts: band.workouts + (band.activeWorkout.map { [$0] } ?? []),excluded: sleeps + personalization.feedback.dismissedActivity,awakeHR: awakeHR)
            if let measured = total.awakeHR { awakeHR = measured }
            personalization.activities = total.unconfirmed
            var sources = [DisplayCalorieSource(id: "rest", name: "Resting", kcal: total.resting, isResting: true, detail: "Your body at rest", symbol: "bed.double.fill")]
            for item in AdaptiveCalories.sources(total, workouts: band.workouts + (band.activeWorkout.map { [$0] } ?? []), now: now) {
                var detail: String
                var symbol = ActivityKind.symbol(for: item.title)
                switch item.kind {
                case .manual: detail = "Started by you"
                case .autoDetected: detail = "Auto-detected"
                case .other: detail = "Everyday movement"; symbol = "figure.walk"
                }
                if let start = item.start, let end = item.end { detail += " · \(Format.time(start))–\(Format.time(end))" }
                sources.append(DisplayCalorieSource(id: item.id, name: item.title, kcal: item.kcal, detail: detail, symbol: symbol))
            }
            day.calories = DisplayCalories(resting: total.resting,active: total.active,goal: profile.dailyCalorieGoal,hourly: total.hourly,sources: sources)

        }
        let today = dayNumber(now)
        if let sleepSession, sleepSession.day == today {
            day.sleepPerformance = sleepSession.session.performance
            switch recovery {
            case .ready(let result)?: day.recovery = DisplayRecovery(score: result.score, band: Self.band(result.band)); day.recoveryEarly = result.early
            case .calibrating(let nights)?: day.recoveryCalibratingNights = nights
            case nil: break
            }
        }
        display.day = day
        publishCalibration()
        display.lastSleep = sleepSession.flatMap { $0.day >= today - 1 ? Self.display($0.session) : nil }
        display.lastSleep?.skinState = lastSkinState

        var all: [UUID: DisplayWorkoutMetrics] = [:]
        for workout in band.workouts.suffix(60) {
            let result = cachedMetrics(workout).0
            all[workout.id] = DisplayWorkoutMetrics(calories: result.calories, strain: result.strain)
        }
        display.workoutMetrics = all
    }

    /// Strain, calories, sleep and workouts for one earlier day, from stored history and today's zones.
    func daySummary(_ date: Date) -> DisplayDaySummary {
        let start = calendar.startOfDay(for: date)
        let end = calendar.date(byAdding: .day, value: 1, to: start) ?? start.addingTimeInterval(86400)
        var summary = DisplayDaySummary(date: start, hasHeartRate: false, workouts: [])
        guard let band else { return summary }
        summary.workouts = band.workouts.filter { $0.start >= start && $0.start < end }.sorted { $0.start < $1.start }
        let series = minuteSeries(from: start, to: end)
        summary.hasHeartRate = series.contains { $0 != nil }
        let sleep = ((try? storage?.sleeps(fromDay: dayNumber(start), toDay: dayNumber(start))) ?? []).first?.session
        summary.asleep = sleep?.asleep; summary.sleepPerformance = sleep?.performance
        if let profile, summary.hasHeartRate {
            let zones = CalibrationEngine.zones(profile: profile, baseline: personalization.baseline)
            summary.strain = CalibrationEngine.score(series, zones: zones)
            let sleeps = sleep.map { [DateInterval(start: $0.start, end: $0.end)] } ?? []
            let total = AdaptiveCalories.estimate(series, from: start, to: end, profile: profile, zones: zones, weights: personalization.feedback.weights, workouts: summary.workouts, excluded: sleeps + personalization.feedback.dismissedActivity, awakeHR: awakeHR)
            summary.calories = total.resting + total.active; summary.activeCalories = total.active
        }
        return summary
    }

    private func todaysWorkouts(_ band: BandManager, since dayStart: Date) -> [Workout] {
        band.workouts.filter { ($0.end ?? Date()) >= dayStart }
    }

    private static func band(_ kind: RecoveryBandKind) -> RecoveryBand {
        switch kind { case .green: .green; case .yellow: .yellow; case .red: .red }
    }

    private static func display(_ s: SleepSession) -> DisplaySleep {
        return DisplaySleep(
            start: s.start, end: s.end, asleep: s.asleep, inBed: s.inBed,
            need: s.need ?? HealthConstants.sleepNeedBaselineHours * 3600, performance: s.performance ?? 0,
            efficiency: s.inBed > 0 ? s.asleep / s.inBed : nil, consistency: s.consistency.map { $0 / 100 },
            segments: s.stages?.compactMap { segment in
                let stage: SleepStage = switch segment.stage { case .awake: .awake; case .rem: .rem; case .light: .light; case .deep: .deep }
                return DisplaySleepSegment(stage: stage, start: segment.start, end: segment.end)
            },
            sleepingHR: Int(s.lowestHR.rounded()), hrv: s.rmssd, respiratoryRate: nil,
            needBaseline: s.needBaseline, needStrain: s.needStrain, needDebt: s.needDebt,
            needNap: s.needNap, disturbances: s.disturbances, cycles: s.cycles, restorative: s.restorativeShare, skinState: nil)
    }

    // MARK: Sleep and recovery

    /// Heart rate while awake and still, from the latest day with enough still minutes. Anchors calorie estimates.
    private var awakeHR: Double? {
        get { let value = UserDefaults.standard.double(forKey: "awakeRestingHR"); return value > 0 ? value : nil }
        set { UserDefaults.standard.set(newValue ?? 0, forKey: "awakeRestingHR") }
    }
    private let sleepWorker = DispatchQueue(label: "personal.sleep", qos: .utility)
    private var sleepRunning = false
    private var sleepPending = false

    /// Finds and scores nights and naps on a background queue, then publishes the results here.
    func recomputeSleep() {
        guard let band, let storage else { return }
        if sleepRunning { sleepPending = true; return }
        sleepRunning = true
        let input = SleepWorkInput(
            url: storage.url, now: Date(), calendar: calendar, profile: profile,
            zones: profile.map { personalization.zones($0) },
            readings: (band.workouts + (band.activeWorkout.map { [$0] } ?? [])).flatMap(\.readings),
            corrections: personalization.feedback.sleepCorrections,
            napDecisions: personalization.feedback.napDecisions ?? [:])
        sleepWorker.async {
            let result = Result { try SleepWork.run(input) }
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.sleepRunning = false
                switch result {
                case .success(let output):
                    if let failure = output.failures.first { self.band?.fail("We couldn't save your sleep. It will retry after the next sync.", HistoryStore.Failure.database(failure)) }
                    self.applySleep(output, now: input.now)
                case .failure(let error):
                    self.band?.fail("We couldn't save your sleep. It will retry after the next sync.", error)
                }
                if self.sleepPending { self.sleepPending = false; self.recomputeSleep() }
            }
        }
    }

    private func applySleep(_ output: SleepWorkOutput, now: Date) {
        let today = dayNumber(now)
        let known = output.known
        let ordered = known.sorted { $0.key < $1.key }
        if let last = ordered.last {
            sleepSession = (last.key, last.value)
            let excluded = Set(personalization.feedback.excludedDays.map { dayNumber($0) })
            let history = ordered.dropLast().filter { entry in entry.key > today - HealthConstants.recoveryBaselineNights && CalibrationNights.verdict(entry.value, excluded: excluded.contains(entry.key)).counts }.map { night($0.value) }
            recovery = CalibrationNights.verdict(last.value, excluded: excluded.contains(last.key)).counts ? RecoveryEngine.score(tonight: night(last.value), baseline: Array(history)) : nil
        } else { sleepSession = nil; recovery = nil }

        if output.newlyFound, let last = ordered.last, last.key == today, now.timeIntervalSince(last.value.end) < HealthConstants.notificationRecency,
           UserDefaults.standard.integer(forKey: "lastSleepNotifiedDay") != today {
            UserDefaults.standard.set(today, forKey: "lastSleepNotifiedDay")
            NotificationService.shared.postSleep(day: today, asleep: last.value.asleep, performance: last.value.performance)
        }
        if case .ready(let result)? = recovery, let last = ordered.last, last.key == today,
           now.timeIntervalSince(last.value.end) < HealthConstants.notificationRecency,
           UserDefaults.standard.integer(forKey: "lastRecoveryNotifiedDay") != today {
            UserDefaults.standard.set(today, forKey: "lastRecoveryNotifiedDay")
            NotificationService.shared.postRecovery(day: today, score: result.score, band: result.band, early: result.early)
        }
        lastKnown = known
        if let last = ordered.last, let tonight = last.value.skinRaw {
            let history = ordered.dropLast().suffix(14).compactMap(\.value.skinRaw)
            lastSkinState = SleepEngine.skinState(tonight: tonight, history: history)?.rawValue
        } else { lastSkinState = nil }
        recomputeToday(force: true)
    }

    private func night(_ s: SleepSession) -> RecoveryEngine.Night {
        RecoveryEngine.Night(restingHR: s.lowestHR, rmssd: s.rmssd, sleepPerformance: s.performance)
    }

    // MARK: Naps and calibration state

    private var lastKnown: [Int: SleepSession] = [:]
    private var lastSkinState: String?

    private func napKey(_ day: Int) -> String { "naps:\(day)" }
    private func storedNaps(day: Int) -> [SleepSession] { (try? storage?.document(napKey(day), as: [SleepSession].self)) ?? [] }
    func decideNap(id: String, keep: Bool) {
        var decisions = personalization.feedback.napDecisions ?? [:]
        decisions[id] = keep
        personalization.feedback.napDecisions = decisions
        personalization.saveFeedback()
    }

    /// One model behind the setup checklist, the calibration card, the night strip and every "not ready" caption.
    private func publishCalibration() {
        guard let band, let display else { return }
        let now = Date()
        let today = dayNumber(now)
        let excluded = Set(personalization.feedback.excludedDays.map { dayNumber($0) })
        var setup = SetupState()
        setup.profileComplete = profile != nil
        setup.bandPaired = band.hasSavedBand
        setup.wornLastNight = sleepSession != nil
        let valid = CalibrationNights.validCount(sessions: lastKnown, excludedDays: excluded, today: today)
        var state = DisplayCalibration()
        state.setup = setup
        state.validNights = valid
        state.phase = CalibrationPhase.make(validNights: valid, setupComplete: setup.isComplete)
        state.nights = CalibrationNights.log(sessions: lastKnown, excludedDays: excluded, today: today)
        state.restingHR = personalization.baseline.restingHR
        state.restingNights = personalization.baseline.resting.count
        state.hrvNights = personalization.baseline.hrv.count
        if let profile { state.zonesProvisional = personalization.zones(profile).provisional }
        if let last = state.nights.last(where: { lastKnown[$0.wakeDay] != nil }), last.wakeDay >= today - 1 {
            if case .missed(let reason) = last.verdict { state.lastNight = "Last night didn't count: " + reason.rawValue.prefix(1).lowercased() + reason.rawValue.dropFirst() }
            else { state.lastNight = "Last night counted" }
        }
        display.calibration = state
        let naps = (confirmedNapsAndPending(day: today))
        display.naps = naps
        display.decideNap = { [weak self] id, keep in self?.decideNap(id: id, keep: keep) }
    }

    private func confirmedNapsAndPending(day: Int) -> [DisplayNap] {
        storedNaps(day: day).compactMap { nap in
            let id = String(nap.start.timeIntervalSince1970)
            let decision = personalization.feedback.napDecisions?[id]
            if decision == false { return nil }
            let long = nap.asleep >= Double(HealthConstants.napDirectMinutes) * 60
            return DisplayNap(id: id, start: nap.start, end: nap.end, asleep: nap.asleep, needsReview: decision == nil && !long)
        }
    }

    // MARK: Detection

    private var detectionEnabled: Bool { UserDefaults.standard.object(forKey: Self.detectionEnabledKey) as? Bool ?? true }

    func runDetection(window: TimeInterval) {
        guard let band, let display, let storage else { return }
        guard detectionEnabled else { display.detections = []; return }
        let now = Date()
        let from = now.addingTimeInterval(-window)
        let series = minuteSeries(from: from, to: now)
        let maxHR = ZoneConfig.maxHR
        let candidates = ActivityDetector.detect(series, firstMinute: firstMinute(from), maxHR: maxHR)
        let existing = (try? storage.detections(since: from.addingTimeInterval(-6 * 3600))) ?? []
        var windows = band.workouts.filter { ($0.end ?? now) >= from }.map { (start: $0.start, end: $0.end ?? now) }
        if let active = band.activeWorkout { windows.append((active.start, now)) }
        for var change in ActivityDetector.reconcile(candidates, existing: existing, workouts: windows) {
            let recent = now.timeIntervalSince(change.end) < HealthConstants.notificationRecency
            if change.status == .pending, !change.notified, recent {
                change.notified = true
                let found = metrics(start: change.start, end: change.end, readings: [])
                NotificationService.shared.postDetected(id: change.id, type: change.guessedType, minutes: Int(change.end.timeIntervalSince(change.start) / 60), avgHR: found.0.avgHR)
            }
            do { try storage.saveDetection(change) } catch { band.fail("We couldn't save a detected workout.", error) }
        }
        publishDetections()
    }

    private func publishDetections() {
        guard let storage, let display else { return }
        let now = Date()
        guard detectionEnabled else { display.detections = []; return }
        let pending = ((try? storage.detections(since: now.addingTimeInterval(-72 * 3600))) ?? []).filter { $0.status == .pending }
        let maxHR = ZoneConfig.maxHR
        display.detections = pending.compactMap { detection in
            let series = minuteSeries(from: detection.start, to: detection.end)
            let trace = series.compactMap { $0 }.map { HRPoint(date: Date(timeIntervalSince1970: Double($0.minute) * 60), bpm: Int($0.average.rounded())) }
            guard !trace.isEmpty else { return nil }
            let found = metrics(start: detection.start, end: detection.end, readings: [])
            return DisplayDetection(id: detection.id, start: detection.start, end: detection.end, guessedType: detection.guessedType, confidence: detection.confidence,
                                    avgHR: found.0.avgHR ?? 0, maxHR: found.0.maxHR ?? 0, calories: found.0.calories, strain: found.0.strain,
                                    trace: trace, zones: HRMath.timeInZones(trace, maxHR: maxHR))
        }
    }

    func confirm(detectionID: String, type: String?) {
        guard let band, let storage else { return }
        guard var detection = ((try? storage.detections(since: .distantPast)) ?? []).first(where: { $0.id == detectionID }), detection.status == .pending else { return }
        let series = minuteSeries(from: detection.start, to: detection.end)
        var workout = Workout(type: type ?? detection.guessedType)
        workout.start = detection.start; workout.end = detection.end
        workout.readings = series.compactMap { $0 }.map { WorkoutReading(date: Date(timeIntervalSince1970: Double($0.minute) * 60), bpm: Int($0.average.rounded())) }
        workout.source = .detected
        band.addWorkout(workout)
        let result = metrics(start: detection.start, end: detection.end, readings: workout.readings)
        workout.metrics = result.0
        metricsCache[workout.id] = result
        detection.status = .confirmed
        try? storage.saveDetection(detection)
        NotificationService.shared.clearDetected(id: detectionID)
        NotificationService.shared.postSaved(id: workout.id.uuidString, type: workout.type, minutes: Int(detection.end.timeIntervalSince(detection.start) / 60), strain: result.0.strain, calories: result.0.calories)
        publishDetections()
        recomputeToday(force: true)
    }

    func dismiss(detectionID: String) {
        guard let storage else { return }
        guard var detection = ((try? storage.detections(since: .distantPast)) ?? []).first(where: { $0.id == detectionID }) else { return }
        personalization.feedback.dismissedActivity.append(DateInterval(start: detection.start,end: detection.end))
        personalization.saveFeedback()
        detection.status = .dismissed
        try? storage.saveDetection(detection)
        NotificationService.shared.clearDetected(id: detectionID)
        publishDetections()
    }
}
