import Foundation

struct CalibrationState: Codable, Equatable {
    var count = 0
    var established = false
    var lastObservation: Date?
    var reason = "Waiting for qualifying data"
    func stale(at now: Date) -> Bool { lastObservation.map { now.timeIntervalSince($0) > 7 * 86400 } ?? true }
}
struct ZoneConfiguration: Codable, Equatable {
    var maximum: Double
    var resting: Double?
    var maximumSource: String
    func zone(_ bpm: Double) -> Int? {
        let rest = resting ?? HealthConstants.defaultRestingHR
        guard bpm.isFinite, bpm > 0, bpm <= 300, maximum > rest else { return nil }
        let ratio = (bpm - rest) / (maximum - rest)
        guard ratio + 1e-10 >= HealthConstants.zoneFloors[0] else { return nil }
        return HealthConstants.zoneFloors.lastIndex { ratio + 1e-10 >= $0 }.map { $0 + 1 }
    }
    /// True while zones use the 70 bpm placeholder instead of a measured resting heart rate.
    var provisional: Bool { resting == nil }
    var boundaries: [Double] {
        let rest = resting ?? HealthConstants.defaultRestingHR
        return HealthConstants.zoneFloors.map { rest + $0 * (maximum - rest) }
    }
}
struct BaselineSnapshot: Codable, Equatable {
    var version = "personal-2"
    var resting = CalibrationState()
    var load = CalibrationState()
    var hrv = CalibrationState()
    var restingHR: Double?
    var targetHR: Double?
    var lastAdapted: Date?
    var notifiedHR: Double?
    var shiftDates: [Date] = []
    var lastNotification: Date?
}
struct MetricProvenance: Codable, Equatable {
    var version: String
    var profile: UserProfile
    var zones: ZoneConfiguration
    var coverage: Double
    var baseline: BaselineSnapshot
}
struct WeightEntry: Codable, Identifiable { var id = UUID(); var date: Date; var kg: Double }
struct HealthFeedback: Codable {
    var excludedDays: [Date] = []
    var weights: [WeightEntry] = []
    var efforts: [String: Int] = [:]
    var strengthNotes: [String: String] = [:]
    var sleepCorrections: [String: DateInterval] = [:]
    var dismissedActivity: [DateInterval] = []
    /// Naps the user confirmed (true) or dismissed (false), keyed by nap start time.
    var napDecisions: [String: Bool]? = nil
}
struct ActivityEstimate: Codable, Identifiable {
    var id: String { "\(start.timeIntervalSince1970)" }
    var start: Date
    var end: Date
    var minutes: [Int64]
}
struct CalibrationDay {
    var start: Date
    var end: Date
    var series: [MinuteHR?]
    var rest: Double?
    var rrWindows = 0
    var excluded = false
}
enum CalibrationEngine {
    static func coverage(_ series: [MinuteHR?]) -> Double {
        guard !series.isEmpty else { return 0 }
        return Double(series.compactMap { $0 }.count) / Double(series.count)
    }
    /// One definition of resting heart rate everywhere: the lowest 5-minute average of minutes fit to measure it.
    static func restingHR(_ night: [MinuteHR]) -> Double? {
        let values = restingCandidates(night)
        guard values.count >= 5 else { return nil }
        return (0...(values.count - 5)).map { values[$0..<($0 + 5)].reduce(0, +) / 5 }.min()
    }
    /// Minutes fit for resting heart rate: still when movement is known, and not a sudden drop of more than 25%
    /// below the surrounding half hour.
    static func restingCandidates(_ night: [MinuteHR]) -> [Double] {
        let values = night.map(\.average)
        let radius = HealthConstants.restingGlitchRadius
        return night.indices.compactMap { index in
            let minute = night[index]
            if let motion = minute.motion, motion > HealthConstants.stillMotion { return nil }
            guard let median = Stats.median(Array(values[max(0, index - radius)...min(values.count - 1, index + radius)])) else { return nil }
            return minute.average < HealthConstants.restingGlitchShare * median ? nil : minute.average
        }
    }
    static func qualifies(_ day: CalibrationDay, now: Date) -> Bool {
        guard day.end <= now, !day.excluded, !day.series.isEmpty, abs(Double(day.series.count) - day.end.timeIntervalSince(day.start) / 60) <= 1, coverage(day.series) >= 0.75 else { return false }
        var gap = 0
        for minute in day.series { gap = minute == nil ? gap + 1 : 0; if gap > 180 { return false } }
        return true
    }
    static func update(_ previous: BaselineSnapshot, days: [CalibrationDay], now: Date) -> BaselineSnapshot {
        var result = previous
        let recent = days.filter { $0.end <= now && $0.end > now.addingTimeInterval(-28 * 86400) && !$0.excluded }.sorted { $0.start < $1.start }
        let load = recent.filter { qualifies($0, now: now) }
        let rest = recent.filter { $0.rest != nil }
        let hrv = rest.filter { $0.rrWindows >= 6 }
        func state(_ old: CalibrationState, _ observations: [CalibrationDay], _ reason: String) -> CalibrationState {
            // Not sticky: it holds while enough recent nights exist and lapses after 14 days with none.
            let last = observations.last?.end ?? old.lastObservation
            let lapsed = last.map { now.timeIntervalSince($0) > Double(HealthConstants.baselineLapseDays) * 86400 } ?? true
            return CalibrationState(count: observations.count, established: observations.count >= HealthConstants.recoveryMinimumNights && !lapsed,
                                    lastObservation: last, reason: reason)
        }
        result.load = state(previous.load, load, "Requires 75% daily coverage and no gap over 3 hours")
        result.resting = state(previous.resting, rest, "Needs 4 h asleep and 80% of the night measured")
        result.hrv = state(previous.hrv, hrv, "Needs six 5-minute windows with enough beat-to-beat data")
        if rest.count >= HealthConstants.recoveryMinimumNights, let target = Stats.median(rest.suffix(HealthConstants.zoneRestingNights).compactMap(\.rest)) {
            result.targetHR = target
            if result.restingHR == nil { result.restingHR = target; result.notifiedHR = target }
            if let last = rest.last?.end, last != previous.lastAdapted {
                result.restingHR = result.restingHR.map { $0 + min(HealthConstants.zoneDriftPerNight, max(-HealthConstants.zoneDriftPerNight, target - $0)) }
                result.lastAdapted = last
                if abs(target - (result.notifiedHR ?? target)) >= 3 { result.shiftDates.append(last) }
                else { result.shiftDates = [] }
                result.shiftDates = Array(Set(result.shiftDates)).sorted().suffix(3).map { $0 }
            }
        }
        return result
    }
    static func zones(profile: UserProfile, baseline: BaselineSnapshot) -> ZoneConfiguration {
        let rest = profile.restingHROverride.map(Double.init) ?? (baseline.resting.count >= HealthConstants.recoveryMinimumNights ? baseline.restingHR : nil)
        let maximum = Double(Zones.maximum(profile))
        return ZoneConfiguration(maximum: maximum, resting: rest.flatMap { $0 < maximum ? $0 : nil }, maximumSource: profile.maxHROverride == nil ? "Based on age" : "Manual")
    }
    static func load(_ series: [MinuteHR?], zones: ZoneConfiguration) -> Double {
        series.compactMap { $0 }.reduce(0) { $0 + Double(zones.zone($1.average) ?? 0) }
    }
    static func score(_ series: [MinuteHR?], zones: ZoneConfiguration) -> Double? {
        guard series.contains(where: { $0 != nil }) else { return nil }
        return (21 * (1 - exp(-load(series, zones: zones) / 200)) * 10).rounded() / 10
    }
    static func context(_ series: [MinuteHR?], days: [CalibrationDay], zones: ZoneConfiguration, now: Date) -> String? {
        guard coverage(series) >= 0.75 else { return nil }
        let values = days.filter { qualifies($0, now: now) }.map { Array($0.series.prefix(series.count)) }.filter { $0.count == series.count && coverage($0) >= 0.75 }.map { load($0, zones: zones) }
        guard values.count >= 7, (Stats.median(values) ?? 0) >= 10 else { return nil }
        let current = load(series, zones: zones)
        let rank = Double(values.filter { $0 < current }.count) / Double(values.count)
        return rank < 0.25 ? "Light" : rank > 0.75 ? "High for you" : "Typical"
    }
    /// Heart-rate efforts outside sleep, workouts and dismissed windows. Uses the same detector as the
    /// "Workout detected" cards, so calories and cards always agree on what counts as an effort.
    static func activities(_ series: [MinuteHR?], zones: ZoneConfiguration, excluded: [DateInterval]) -> [ActivityEstimate] {
        guard let anchor = series.enumerated().first(where: { $0.element != nil }), let anchorMinute = anchor.element?.minute else { return [] }
        let firstMinute = anchorMinute - Int64(anchor.offset)
        let masked = series.map { minute -> MinuteHR? in
            guard let minute else { return nil }
            let date = Date(timeIntervalSince1970: Double(minute.minute) * 60)
            return excluded.contains(where: { $0.start <= date && date < $0.end }) ? nil : minute
        }
        return ActivityDetector.detect(masked, firstMinute: firstMinute, maxHR: Int(zones.maximum.rounded())).map { candidate in
            let minutes = (candidate.startMinute...candidate.endMinute).filter { minute in
                let index = Int(minute - firstMinute)
                return index >= 0 && index < masked.count && masked[index] != nil
            }
            return ActivityEstimate(start: candidate.start, end: candidate.end, minutes: minutes)
        }
    }
    static func profile(_ profile: UserProfile, at date: Date, weights: [WeightEntry]) -> UserProfile {
        var result = profile
        if let entry = weights.filter({ $0.date <= date && $0.kg.isFinite && (25...350).contains($0.kg) }).max(by: { $0.date < $1.date }) { result.weightKg = entry.kg }
        return result
    }
}

struct AdaptiveEnergy {
    var resting = 0.0
    var active = 0.0
    var hourly: [Double?] = Array(repeating: nil,count: 24)
    var unconfirmed: [ActivityEstimate] = []
    /// Active kilocalories per minute (minutes since 1970), the basis for naming where active burn came from.
    var activeByMinute: [Int64: Double] = [:]
    /// Median heart rate while awake and still in this window, when there was enough of it.
    var awakeHR: Double?
}

struct ActiveCalorieSource: Equatable {
    enum Kind: Equatable { case manual, autoDetected, other }
    var id: String
    var title: String
    var start: Date?
    var end: Date?
    var kind: Kind
    var kcal: Double
}

extension AdaptiveCalories {
    /// Splits a day's active calories into the workouts and detected activities they came from.
    /// The parts always add up to `energy.active`; whatever is left over is "Other movement".
    static func sources(_ energy: AdaptiveEnergy, workouts: [Workout], now: Date) -> [ActiveCalorieSource] {
        var rows: [ActiveCalorieSource] = []
        var counted = Set<Int64>()
        func sum(_ start: Date, _ end: Date, claim: Bool) -> Double {
            let first = Int64(floor(start.timeIntervalSince1970 / 60)), last = Int64(ceil(end.timeIntervalSince1970 / 60))
            guard last > first else { return 0 }
            var total = 0.0
            for minute in first..<last where !counted.contains(minute) {
                if let kcal = energy.activeByMinute[minute] { total += kcal; if claim { counted.insert(minute) } }
            }
            return total
        }
        for workout in workouts.sorted(by: { $0.start < $1.start }) {
            let end = workout.end ?? now
            let kcal = sum(workout.start, end, claim: true)
            guard kcal >= 1 else { continue }
            rows.append(ActiveCalorieSource(id: "workout-\(workout.id.uuidString)", title: workout.type, start: workout.start, end: end,
                                            kind: workout.source == .detected ? .autoDetected : .manual, kcal: kcal))
        }
        for activity in energy.unconfirmed {
            let kcal = sum(activity.start, activity.end, claim: true)
            guard kcal >= 1 else { continue }
            rows.append(ActiveCalorieSource(id: "auto-\(activity.id)", title: "Detected activity", start: activity.start, end: activity.end, kind: .autoDetected, kcal: kcal))
        }
        let rest = energy.active - rows.reduce(0) { $0 + $1.kcal }
        if rest >= 1 { rows.append(ActiveCalorieSource(id: "other", title: "Other movement", start: nil, end: nil, kind: .other, kcal: rest)) }
        return rows
    }
}
enum AdaptiveCalories {
    static func supported(_ type: String) -> Bool { ["running","walking","cycling","hiking","rowing","swimming","elliptical"].contains(type.lowercased()) }
    static func estimate(_ series: [MinuteHR?], from: Date, to: Date, profile: UserProfile, zones: ZoneConfiguration, weights: [WeightEntry], workouts: [Workout], excluded: [DateInterval], awakeHR: Double? = nil, calendar: Calendar = .current) -> AdaptiveEnergy {
        var result = AdaptiveEnergy()
        guard to > from, profile.validationError == nil else { return result }
        let blocked = excluded + workouts.flatMap { workout -> [DateInterval] in
            var intervals = workout.pauses ?? []
            if let pause = workout.pausedAt { intervals.append(DateInterval(start: pause,end: max(pause,to))) }
            if !supported(workout.type) { intervals.append(DateInterval(start: workout.start,end: max(workout.start,workout.end ?? to))) }
            return intervals
        }
        result.unconfirmed = CalibrationEngine.activities(series,zones: zones,excluded: blocked + workouts.map { DateInterval(start: $0.start,end: max($0.start,$0.end ?? to)) })
        let activeMinutes = Set(result.unconfirmed.flatMap(\.minutes))
        let known = Dictionary(series.compactMap { $0 }.map { ($0.minute,$0) },uniquingKeysWith: { first,_ in first })
        let sleepingHR = zones.resting ?? HealthConstants.defaultRestingHR
        let vo2max = EnergyModel.vo2max(maximumHR: zones.maximum, restingHR: sleepingHR)
        // Oxygen uptake scales from the heart rate while awake and still, not the overnight low.
        let still = known.values.filter { minute in
            let time = Date(timeIntervalSince1970: Double(minute.minute) * 60)
            return (minute.motion.map { $0 <= HealthConstants.stillMotion } ?? false) && !excluded.contains { $0.start <= time && time < $0.end }
        }.map(\.average)
        result.awakeHR = still.count >= HealthConstants.quietBaselineMinutes ? Stats.median(still) : nil
        let awake = min(zones.maximum - 40, result.awakeHR ?? awakeHR ?? sleepingHR + HealthConstants.awakeRestingOffset)
        let flex = EnergyModel.flexHR(maximumHR: zones.maximum, restingHR: awake)
        var time = from
        while time < to {
            let minute = Int64(floor(time.timeIntervalSince1970 / 60))
            let end = min(to,Date(timeIntervalSince1970: Double(minute + 1) * 60))
            let fraction = end.timeIntervalSince(time) / 60
            let p = CalibrationEngine.profile(profile,at: time,weights: weights)
            let rest = (CalorieEngine.bmr(p) ?? 0) / 1440
            var active = 0.0
            let isBlocked = blocked.contains { $0.start <= time && time < $0.end }
            let confirmed = workouts.contains { supported($0.type) && $0.start <= time && time < ($0.end ?? to) }
            // Workouts and detected activities count from the flex heart rate up; other minutes only
            // when the wrist is also moving, so a raised heart rate from stress or caffeine stays at rest.
            if !isBlocked, let sample = known[minute], sample.average >= flex {
                let moving = sample.motion.map { $0 >= HealthConstants.energyMoveMotion } ?? false
                if activeMinutes.contains(minute) || confirmed || moving {
                    active = EnergyModel.activeKcal(hr: sample.average, weightKg: p.weightKg, maximumHR: zones.maximum, restingHR: awake, vo2max: vo2max, restPerMinute: rest) * fraction
                }
            }
            result.resting += rest * fraction; result.active += active
            if active > 0 { result.activeByMinute[minute, default: 0] += active }
            let hour = calendar.component(.hour,from: time)
            result.hourly[hour] = (result.hourly[hour] ?? 0) + rest * fraction + active
            time = end
        }
        return result
    }
}
