import Foundation

enum Zones {
    static func maximum(_ profile: UserProfile) -> Int { profile.maxHROverride ?? Int((208 - 0.7 * Double(profile.ageYears)).rounded()) }
    static func zone(bpm: Double, profile: UserProfile) -> Int? {
        guard profile.validationError == nil, bpm.isFinite, bpm > 0, bpm <= 300 else { return nil }
        let rest = profile.restingHROverride.map(Double.init) ?? HealthConstants.defaultRestingHR
        let reserve = Double(maximum(profile)) - rest
        guard reserve > 0 else { return nil }
        let ratio = (bpm - rest) / reserve
        return HealthConstants.zoneFloors.lastIndex { ratio + 1e-10 >= $0 }.map { $0 + 1 }
    }
    static func seconds(_ series: [MinuteHR?], profile: UserProfile) -> [Int: Double] {
        var result = Dictionary(uniqueKeysWithValues: (1...5).map { ($0, 0.0) })
        for minute in series.compactMap({ $0 }) {
            if let zone = zone(bpm: minute.average, profile: profile) { result[zone, default: 0] += 60 }
        }
        return result
    }
}
enum StrainEngine {
    static func score(_ series: [MinuteHR?], profile: UserProfile) -> Double? {
        guard profile.validationError == nil, series.contains(where: { $0 != nil }) else { return nil }
        let load = Zones.seconds(series, profile: profile).reduce(0.0) { $0 + $1.value / 60 * Double($1.key) }
        return (21 * (1 - exp(-load / HealthConstants.strainScale)) * 10).rounded() / 10
    }
}
