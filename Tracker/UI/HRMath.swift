import SwiftUI

/// One heart-rate point, regardless of where it came from (live stream, history, workout).
struct HRPoint: Identifiable, Hashable {
    var date: Date
    var bpm: Int
    var id: Date { date }
}

struct HRStats {
    var min: Int
    var avg: Int
    var max: Int
}

/// Five heart-rate zones as a share of max heart rate. Below 50% is "no zone".
enum ZoneBand: Int, CaseIterable, Identifiable {
    case z1 = 1, z2, z3, z4, z5
    var id: Int { rawValue }

    var color: Color {
        switch self {
        case .z1: Palette.zone1
        case .z2: Palette.zone2
        case .z3: Palette.zone3
        case .z4: Palette.zone4
        case .z5: Palette.zone5
        }
    }
    var title: String { "Zone \(rawValue)" }
    var shortTitle: String { "Z\(rawValue)" }
    var intensity: String {
        switch self {
        case .z1: "Light"
        case .z2: "Moderate"
        case .z3: "Vigorous"
        case .z4: "Hard"
        case .z5: "Maximum"
        }
    }
    /// Lower bound as a fraction of max heart rate.
    var floor: Double { HealthConstants.zoneFloors[rawValue - 1] }
    var ceiling: Double { rawValue < 5 ? HealthConstants.zoneFloors[rawValue] : 1 }

    func floorBPM(maxHR: Int) -> Int { Int(((ZoneConfig.resting ?? HealthConstants.defaultRestingHR) + floor * (Double(maxHR) - (ZoneConfig.resting ?? HealthConstants.defaultRestingHR))).rounded()) }
    func ceilingBPM(maxHR: Int) -> Int { Int(((ZoneConfig.resting ?? HealthConstants.defaultRestingHR) + ceiling * (Double(maxHR) - (ZoneConfig.resting ?? HealthConstants.defaultRestingHR))).rounded()) }

    static func band(for bpm: Int, maxHR: Int) -> ZoneBand? {
        let resting = ZoneConfig.resting ?? HealthConstants.defaultRestingHR
        let fraction = (Double(bpm) - resting) / max(1,Double(maxHR) - resting)
        guard fraction >= HealthConstants.zoneFloors[0] else { return nil }
        return ZoneBand.allCases.last { fraction >= $0.floor } ?? .z1
    }
}

enum ZoneConfig {
    static var resting: Double? {
        if let profile = HealthEngine.loadProfile(), let manual = profile.restingHROverride { return Double(manual) }
        guard let data = UserDefaults.standard.data(forKey: "calibratedZones"), let zones = try? JSONDecoder().decode(ZoneConfiguration.self,from: data), zones.maximum == Double(maxHR) else { return nil }
        return zones.resting
    }

    /// Legacy manual override, used only while no profile exists.
    static let maxHRKey = "uiMaxHR"
    /// Max heart rate for zones: the profile (override, else age-based) → manual value → 190.
    static var maxHR: Int {
        if let profile = HealthEngine.loadProfile() { return Zones.maximum(profile) }
        let stored = UserDefaults.standard.integer(forKey: maxHRKey)
        return stored >= 120 && stored <= 230 ? stored : 190
    }
}

enum HRMath {
    static func stats(_ points: [HRPoint]) -> HRStats? {
        guard !points.isEmpty else { return nil }
        let values = points.map(\.bpm)
        return HRStats(min: values.min() ?? 0,
                       avg: Int((Double(values.reduce(0, +)) / Double(values.count)).rounded()),
                       max: values.max() ?? 0)
    }

    /// Time spent in each zone. Every point holds until the next one, with gaps longer than
    /// `maxGap` (band off, out of range) not counted so missing data is never read as exertion.
    static func timeInZones(_ points: [HRPoint], maxHR: Int, maxGap: TimeInterval = 120) -> [ZoneBand: TimeInterval] {
        var result: [ZoneBand: TimeInterval] = [:]
        let sorted = points.sorted { $0.date < $1.date }
        for (index, point) in sorted.enumerated() where index + 1 < sorted.count {
            let gap = sorted[index + 1].date.timeIntervalSince(point.date)
            guard gap > 0, gap <= maxGap, let band = ZoneBand.band(for: point.bpm, maxHR: maxHR) else { continue }
            result[band, default: 0] += gap
        }
        return result
    }
}

extension Sample {
    var point: HRPoint { HRPoint(date: date, bpm: bpm) }
}

extension WorkoutReading {
    var point: HRPoint { HRPoint(date: date, bpm: bpm) }
}
