import SwiftUI
import UserNotifications

struct PersonalMetricResult: Codable {
    var strain: Double?
    var calories: Double?
    var provenance: MetricProvenance
}
@MainActor final class Personalization: ObservableObject {
    @Published var baseline = BaselineSnapshot()
    @Published var feedback = HealthFeedback()
    @Published var activities: [ActivityEstimate] = []
    @Published var message: String?
    @Published var working = false
    var days: [CalibrationDay] = []
    var changed: (() -> Void)?
    var revisionRequested: (() -> Void)?
    private var store: HistoryStore?
    private let worker = DispatchQueue(label: "personal.calibration", qos: .utility)
    private var revision = 0
    private var pending = false
    private var lastWorkouts: [Workout] = []
    func attach(_ store: HistoryStore?) {
        guard self.store == nil, let store else { return }
        self.store = store
        do {
            baseline = try store.document("baseline", as: BaselineSnapshot.self) ?? BaselineSnapshot()
            feedback = try store.document("feedback", as: HealthFeedback.self) ?? HealthFeedback()
        } catch { message = "We couldn't save that. Please try again." }
    }
    func saveFeedback() {
        do { try store?.saveDocument(feedback,key: "feedback"); revision += 1; refresh(workouts: lastWorkouts); revisionRequested?(); changed?() }
        catch { message = "We couldn't save that. Please try again." }
    }
    func refresh(workouts: [Workout]) {
        lastWorkouts = workouts
        guard let store else { return }
        if working { pending = true; return }
        working = true
        let url = store.url, feedback = feedback, previous = baseline, generation = revision
        let now = Date(), calendar = Calendar.current
        let currentProfile = HealthEngine.loadProfile()
        worker.async { [weak self] in
            let outcome: Result<([CalibrationDay], BaselineSnapshot), Error> = Result {
                let storage = try HistoryStore(url: url)
                let today = calendar.startOfDay(for: now)
                let first = calendar.date(byAdding: .day,value: -28,to: today)!
                let history = try storage.samples(from: first,to: today)
                let live = try storage.liveMinutes(from: first,to: today)
                let details = try storage.historyMinutes(from: first,to: today)
                let dayNumber = Int(((today.timeIntervalSince1970 + Double(calendar.timeZone.secondsFromGMT(for: today))) / 86400).rounded())
                let sleeps = try storage.sleeps(fromDay: dayNumber - 29,toDay: dayNumber).map(\.session)
                var days: [CalibrationDay] = []
                for offset in -28..<0 {
                    let start = calendar.date(byAdding: .day,value: offset,to: today)!
                    let end = calendar.date(byAdding: .day,value: 1,to: start)!
                    let series = HRTimeline.minuteSeries(history: history, live: live, workoutReadings: [], details: details, from: start,to: end)
                    var rest: Double?; var rr = 0
                    if let sleep = sleeps.last(where: { $0.end >= start && $0.end < end }) {
                        let key = String(sleep.start.timeIntervalSince1970)
                        let interval = feedback.sleepCorrections[key] ?? DateInterval(start: sleep.start,end: sleep.end)
                        let night = HRTimeline.minuteSeries(history: history,live: live,workoutReadings: [],details: details,from: interval.start,to: interval.end).map { minute -> MinuteHR? in
                            guard let minute else { return nil }
                            let time = Date(timeIntervalSince1970: Double(minute.minute) * 60)
                            return workouts.contains(where: { $0.start <= time && ($0.end ?? now) > time }) ? nil : minute
                        }
                        let values = night.compactMap { $0 }
                        if values.count >= 240, CalibrationEngine.coverage(night) >= 0.8 {
                            rest = CalibrationEngine.restingHR(values)
                            rr = stride(from: 0, to: night.count - 4, by: 5).filter { HRTimeline.pooledRMSSD(Array(night[$0..<($0 + 5)])) != nil }.count
                        }
                    }
                    days.append(CalibrationDay(start: start,end: end,series: series,rest: rest,rrWindows: rr,excluded: feedback.excludedDays.contains(where: { calendar.isDate($0,inSameDayAs: start) })))
                }
                let updated = CalibrationEngine.update(previous, days: days, now: now)
                if let currentProfile {
                    for day in days {
                        let key = "day:\(day.start.timeIntervalSince1970)"
                        let frozen = try storage.document(key + ":baseline",as: BaselineSnapshot.self) ?? updated
                        let profile = try storage.document(key + ":profile",as: UserProfile.self) ?? currentProfile
                        try storage.saveDocument(frozen,key: key + ":baseline")
                        try storage.saveDocument(profile,key: key + ":profile")
                        let zones = CalibrationEngine.zones(profile: profile,baseline: frozen)
                        let exclusions = sleeps.map { DateInterval(start: $0.start,end: $0.end) } + feedback.dismissedActivity
                        let energy = AdaptiveCalories.estimate(day.series,from: day.start,to: day.end,profile: profile,zones: zones,weights: feedback.weights,workouts: workouts,excluded: exclusions,calendar: calendar)
                        let result = PersonalMetricResult(strain: CalibrationEngine.score(day.series,zones: zones),calories: energy.resting + energy.active,provenance: MetricProvenance(version: frozen.version,profile: profile,zones: zones,coverage: CalibrationEngine.coverage(day.series),baseline: frozen))
                        try storage.saveRevision(result,key: key)
                    }
                }
                return (days, updated)
            }
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.working = false
                if generation == self.revision {
                    switch outcome {
                    case .success(let (days, baseline)):
                        self.days = days; self.baseline = baseline
                        do { try self.store?.saveDocument(baseline,key: "baseline") } catch { self.message = "We couldn't save that. Please try again." }
                        self.notifyShift(); self.changed?()
                    case .failure(let error): self.message = "We couldn't save that. Please try again."
                    }
                }
                if self.pending || generation != self.revision { self.pending = false; self.refresh(workouts: self.lastWorkouts) }
            }
        }
    }
    private func notifyShift() {
        guard HealthEngine.loadProfile()?.restingHROverride == nil, baseline.shiftDates.count >= 3, let target = baseline.targetHR,
              baseline.lastNotification.map({ Date().timeIntervalSince($0) >= 7 * 86400 }) ?? true else { return }
        baseline.notifiedHR = target; baseline.lastNotification = Date(); baseline.shiftDates = []
        do { try store?.saveDocument(baseline,key: "baseline") } catch { message = "We couldn't save that. Please try again."; return }
        message = "Your overnight resting-HR baseline has shifted. Future HR zones now adapt gradually."
        let text = message!
        Task {
            let center = UNUserNotificationCenter.current()
            let settings = await center.notificationSettings()
            guard settings.authorizationStatus == .authorized || settings.authorizationStatus == .provisional else { return }
            let content = UNMutableNotificationContent(); content.title = "HR zone baseline updated"; content.body = text
            try? await center.add(UNNotificationRequest(identifier: "zone-shift",content: content,trigger: nil))
        }
    }
    func zones(_ profile: UserProfile) -> ZoneConfiguration {
        let zones = CalibrationEngine.zones(profile: profile,baseline: baseline)
        if let data = try? JSONEncoder().encode(zones) { UserDefaults.standard.set(data,forKey: "calibratedZones") }
        return zones
    }
    func frozenProfile(_ profile: UserProfile,key: String) -> UserProfile {
        do {
            if let saved = try store?.document(key,as: UserProfile.self) { return saved }
            try store?.saveDocument(profile,key: key)
        } catch { message = "We couldn't save that. Please try again." }
        return profile
    }
    func frozenBaseline(key: String) -> BaselineSnapshot {
        do {
            if let saved = try store?.document(key,as: BaselineSnapshot.self) { return saved }
            try store?.saveDocument(baseline,key: key)
        } catch { message = "We couldn't save that. Please try again." }
        return baseline
    }

    func profile(_ profile: UserProfile, at date: Date) -> UserProfile { CalibrationEngine.profile(profile,at: date,weights: feedback.weights) }
    /// Strain needs only a profile now: it is provisional until resting HR is measured, not hidden.
    var strainReady: Bool { true }
    var progress: String { baseline.resting.established ? "Personalized · experimental" : "Provisional · learning your resting heart rate" }
    func saveResult(_ result: PersonalMetricResult, key: String) {
        do { try store?.saveRevision(result,key: key) } catch { message = "We couldn't save that. Please try again." }
    }
    /// A readable JSON file of everything Pulse holds about the user, for sharing or keeping.
    func exportFile(profile: UserProfile?, workouts: [Workout]) -> URL? {
        struct Export: Encodable {
            var exported: Date; var profile: UserProfile?; var workouts: [Workout]; var sleeps: [SleepSession]
            var weights: [WeightEntry]; var baseline: BaselineSnapshot; var heartRateMinutes: [MinuteHR]; var metricRevisions: [String]
        }
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted,.sortedKeys]; encoder.dateEncodingStrategy = .iso8601
        let now = Date(), from = now.addingTimeInterval(-90 * 86400)
        let sleeps = ((try? store?.sleeps(fromDay: 0,toDay: 1_000_000)) ?? []).map(\.session)
        let minutes = (try? store?.liveMinutes(from: from,to: now)) ?? []
        let export = Export(exported: now,profile: profile,workouts: workouts,sleeps: sleeps,weights: feedback.weights,baseline: baseline,heartRateMinutes: minutes,metricRevisions: (try? store?.metricRevisions()) ?? [])
        guard let data = try? encoder.encode(export) else { return nil }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("Pulse-data-\(ISO8601DateFormatter().string(from: now).prefix(10)).json")
        do { try data.write(to: url,options: .atomic); return url } catch { return nil }
    }
    /// Wipe stored results and clear what is held in memory.
    func eraseAll() {
        try? store?.eraseAll()
        baseline = BaselineSnapshot(); feedback = HealthFeedback(); activities = []; days = []; message = nil
    }
    func export() -> String {
        struct Export: Encodable { var baseline: BaselineSnapshot; var feedback: HealthFeedback; var activities: [ActivityEstimate]; var samples: [Sample]; var liveMinutes: [MinuteHR]; var revisions: [String] }
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted,.sortedKeys]; encoder.dateEncodingStrategy = .iso8601
        return (try? String(decoding: encoder.encode(Export(baseline: baseline,feedback: feedback,activities: activities,samples: (try? store?.samples(from: Date().addingTimeInterval(-28 * 86400),to: Date())) ?? [],liveMinutes: (try? store?.liveMinutes(from: Date().addingTimeInterval(-28 * 86400),to: Date())) ?? [],revisions: (try? store?.metricRevisions()) ?? [])),as: UTF8.self)) ?? "Export unavailable"
    }
}
