import Foundation

struct HeartRateReading {
    let bpm: Int
    let rrMilliseconds: [Double]
    static func proprietary(_ bytes: [UInt8]) -> HeartRateReading? {
        if bytes.count >= 1287, bytes[0] == 0x2b, bytes[1] == 10, bytes[17] > 0 {
            return HeartRateReading(bpm: Int(bytes[17]), rrMilliseconds: [])
        }
        guard bytes.count >= 20, bytes.count < 64, bytes[0] == 0x28,
              bytes[18] == 0, bytes[8] > 0 else { return nil }
        return HeartRateReading(bpm: Int(bytes[8]), rrMilliseconds: [])
    }
    static func parse(_ bytes: [UInt8]) -> HeartRateReading? {
        guard let flags = bytes.first, bytes.count >= 2 else { return nil }
        var offset = 2
        var bpm = Int(bytes[1])
        if flags & 1 != 0 {
            guard bytes.count >= 3 else { return nil }
            bpm |= Int(bytes[2]) << 8; offset = 3
        }
        if flags & 4 != 0 && flags & 2 == 0 { return nil }
        if flags & 8 != 0 { offset += 2 }
        guard offset <= bytes.count, bpm > 0 else { return nil }
        var rr: [Double] = []
        if flags & 16 != 0 {
            guard (bytes.count - offset) % 2 == 0 else { return nil }
            while offset + 1 < bytes.count {
                rr.append(Double(Int(bytes[offset]) | Int(bytes[offset + 1]) << 8) * 1000 / 1024)
                offset += 2
            }
        }
        return HeartRateReading(bpm: bpm, rrMilliseconds: rr)
    }
}

struct Workout: Codable, Identifiable {
    var id = UUID()
    var type: String
    var start = Date()
    var end: Date?
    var pausedAt: Date?
    var pausedSeconds: Double = 0
    var pauses: [DateInterval]?
    var readings: [WorkoutReading] = []
    /// Optional so workouts saved before these fields existed still decode. `nil` source means manual.
    var source: WorkoutSource?
    var metrics: WorkoutMetrics?
    func elapsed(at now: Date) -> Double { max(0, (end ?? pausedAt ?? now).timeIntervalSince(start) - pausedSeconds) }
}
struct WorkoutReading: Codable { var date: Date; var bpm: Int }
