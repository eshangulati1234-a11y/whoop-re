import Foundation

struct CalorieBreakdown: Codable { var resting: Double; var active: Double; var isEstimate = true; var total: Double { resting + active } }
enum CalorieEngine {
    static func bmr(_ p: UserProfile) -> Double? {
        guard p.validationError == nil else { return nil }
        return 10 * p.weightKg + 6.25 * p.heightCm - 5 * Double(p.ageYears) + (p.sex == .male ? 5 : -161)
    }
    /// Active kcal for one minute at this average HR (Keytel et al. 2005 minus resting). Zero below zone 1.
    static func activeKcal(minuteAverage hr: Double, profile p: UserProfile, restPerMinute rest: Double) -> Double {
        guard Zones.zone(bpm: hr, profile: p) != nil else { return 0 }
        let gross: Double
        if p.sex == .male { gross = (-55.0969 + 0.6309 * hr + 0.1988 * p.weightKg + 0.2017 * Double(p.ageYears)) / 4.184 }
        else { gross = (-20.4022 + 0.4472 * hr - 0.1263 * p.weightKg + 0.074 * Double(p.ageYears)) / 4.184 }
        return max(0, gross - rest)
    }
    static func estimate(_ series: [MinuteHR?], profile p: UserProfile, elapsedMinutes: Double) -> CalorieBreakdown? {
        guard let bmr = bmr(p), elapsedMinutes.isFinite, elapsedMinutes >= 0 else { return nil }
        let rest = bmr / 1440
        var active = 0.0
        // Do not estimate more activity than the elapsed window contains.
        for minute in series.prefix(Int(min(elapsedMinutes, 527040))).compactMap({ $0 }) {
            active += activeKcal(minuteAverage: minute.average, profile: p, restPerMinute: rest)
        }
        return CalorieBreakdown(resting: rest * elapsedMinutes, active: active)
    }
    /// Total kcal per clock hour for a series that starts at local midnight. Hours that have not started are `nil`.
    static func hourly(_ series: [MinuteHR?], profile p: UserProfile, elapsedMinutes: Double) -> [Double?]? {
        guard let bmr = bmr(p), elapsedMinutes.isFinite, elapsedMinutes >= 0 else { return nil }
        let rest = bmr / 1440
        return (0..<24).map { hour -> Double? in
            let first = hour * 60
            guard Double(first) < elapsedMinutes else { return nil }
            let minutes = min(60, elapsedMinutes - Double(first))
            var total = rest * minutes
            for index in first..<min(series.count, first + Int(minutes.rounded(.up))) {
                if let minute = series[index] { total += activeKcal(minuteAverage: minute.average, profile: p, restPerMinute: rest) }
            }
            return total
        }
    }
}

/// Oxygen-uptake energy model, modelled on the published structure of Firstbeat's method (used by Garmin):
/// heart rate → share of heart-rate reserve → oxygen uptake from an estimated VO2max → kcal,
/// with resting-level energy below a "flex" heart rate unless the wrist is moving.
/// Firstbeat's own neural network, respiration and on/off inputs are not public and are not reproduced.
enum EnergyModel {
    /// ml/kg/min. Uth et al. 2004: VO2max ≈ 15.3 × HRmax / HRrest, clamped to a plausible range.
    static func vo2max(maximumHR: Double, restingHR: Double) -> Double {
        guard maximumHR > restingHR, restingHR > 30 else { return 40 }
        return min(HealthConstants.vo2maxRange.upperBound, max(HealthConstants.vo2maxRange.lowerBound, 15.3 * maximumHR / restingHR))
    }
    /// Heart rate under which energy stays at resting level unless the wrist is moving.
    static func flexHR(maximumHR: Double, restingHR: Double) -> Double {
        restingHR + HealthConstants.flexReserveShare * (maximumHR - restingHR)
    }
    /// kcal per litre of oxygen, from about 4.7 (fat, light effort) to about 5.05 (carbohydrate, hard effort).
    static func kcalPerLitre(reserveShare: Double) -> Double { 4.69 + 0.36 * min(1, max(0, reserveShare)) }
    /// Gross kcal for one minute at this heart rate. Swain 1997: % of heart-rate reserve ≈ % of VO2 reserve.
    static func grossKcal(hr: Double, weightKg: Double, maximumHR: Double, restingHR: Double, vo2max: Double) -> Double {
        guard hr.isFinite, maximumHR > restingHR, weightKg > 0 else { return 0 }
        let share = min(1.05, max(0, (hr - restingHR) / (maximumHR - restingHR)))
        let vo2 = 3.5 + share * (vo2max - 3.5)              // ml/kg/min
        return vo2 * weightKg / 1000 * kcalPerLitre(reserveShare: share)
    }
    /// Active kcal above resting for one minute.
    static func activeKcal(hr: Double, weightKg: Double, maximumHR: Double, restingHR: Double, vo2max: Double, restPerMinute: Double) -> Double {
        max(0, grossKcal(hr: hr, weightKg: weightKg, maximumHR: maximumHR, restingHR: restingHR, vo2max: vo2max) - restPerMinute)
    }
}
