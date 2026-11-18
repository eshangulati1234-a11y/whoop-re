import Foundation

struct MinuteHR: Codable, Equatable {
    var minute: Int64
    var average: Double
    var minimum: Int
    var maximum: Int
    var count: Int
    var rmssd: Double?
    var validRRCount: Int?
    /// From history records. `motion` is mean gravity change in milli-g; RR pairs pool across minutes for RMSSD.
    var motion: Double? = nil
    var rrPairs: Int? = nil
    var rrSumSquares: Double? = nil
    var skinRaw: Double? = nil
}
/// One minute of decoded history records.
struct HistoryMinute: Equatable {
    var minute: Int64
    var bpmAverage: Double
    var bpmMinimum: Int
    var bpmMaximum: Int
    var count: Int
    var motion: Double?
    var rrPairs: Int
    var rrSumSquares: Double
    var redIR: Double?
    var skinRaw: Double?
}
enum HRTimeline {
    /// Group per-second records into minutes. RR differences are taken only inside one record (successive
    /// beats), never across records, because beats between records may be missing. Differences over 20% of
    /// the pair's mean are treated as artefact and dropped.
    static func aggregate(_ records: [HistoryProtocol.Record]) -> [HistoryMinute] {
        var byMinute: [Int64: [HistoryProtocol.Record]] = [:]
        for record in records where record.bpm > 0 && record.bpm <= 300 { byMinute[Int64(record.time / 60), default: []].append(record) }
        return byMinute.keys.sorted().map { minute in
            let rows = byMinute[minute]!.sorted { $0.time < $1.time }
            var pairs = 0; var sumSquares = 0.0
            for row in rows {
                for (a, b) in zip(row.rr, row.rr.dropFirst()) where abs(Double(b - a)) <= 0.2 * Double(a + b) / 2 {
                    pairs += 1; sumSquares += Double((b - a) * (b - a))
                }
            }
            var change = 0.0; var changes = 0
            for (previous, next) in zip(rows, rows.dropFirst()) where next.time - previous.time == 1 {
                guard let g = previous.gravity, let h = next.gravity else { continue }
                let d = (0..<3).map { Double(h[$0] - g[$0]) }
                change += (d.map { $0 * $0 }.reduce(0, +)).squareRoot() * 1000; changes += 1
            }
            let optical = rows.filter { $0.red > 0 && $0.ir > 0 }.map { Double($0.red) / Double($0.ir) }
            let skin = rows.filter { $0.skinRaw > 0 }.map { Double($0.skinRaw) }
            let bpm = rows.map(\.bpm)
            return HistoryMinute(minute: minute, bpmAverage: Double(bpm.reduce(0, +)) / Double(bpm.count), bpmMinimum: bpm.min()!, bpmMaximum: bpm.max()!,
                                 count: rows.count, motion: changes >= 10 ? change / Double(changes) : nil, rrPairs: pairs, rrSumSquares: sumSquares,
                                 redIR: optical.isEmpty ? nil : optical.reduce(0, +) / Double(optical.count),
                                 skinRaw: skin.isEmpty ? nil : skin.reduce(0, +) / Double(skin.count))
        }
    }
    /// Night RMSSD: the median of 5-minute pooled windows, needing at least 6 windows of 20 pairs each.
    /// Beat-to-beat intervals in history are sparse and were not validated against heart rate, so treat as an estimate.
    static func nightRMSSD(_ minutes: ArraySlice<MinuteHR?>) -> Double? {
        let items = Array(minutes)
        var windows: [Double] = []
        var start = 0
        while start + 5 <= items.count {
            if let value = pooledRMSSD(Array(items[start..<(start + 5)])) { windows.append(value) }
            start += 5
        }
        return windows.count >= 6 ? Stats.median(windows) : nil
    }
    /// RMSSD pooled over a run of minutes. Needs `minimumPairs` successive-beat differences in total.
    static func pooledRMSSD(_ minutes: [MinuteHR?], minimumPairs: Int = 20) -> Double? {
        var pairs = 0; var sum = 0.0
        for case let minute? in minutes { pairs += minute.rrPairs ?? 0; sum += minute.rrSumSquares ?? 0 }
        return pairs >= minimumPairs ? (sum / Double(pairs)).squareRoot() : nil
    }
    static func medianGapSeconds(_ samples: [Sample]) -> Double? {
        let times = Set(samples.map { $0.date.timeIntervalSince1970 }.filter { $0.isFinite }).sorted()
        let gaps = zip(times, times.dropFirst()).map { $1 - $0 }.sorted()
        guard !gaps.isEmpty else { return nil }
        let mid = gaps.count / 2
        return gaps.count % 2 == 0 ? (gaps[mid-1] + gaps[mid]) / 2 : gaps[mid]
    }
    static func rmssd(_ rr: [Double]) -> Double? {
        // Discarding intervals would bridge missing beats; reject invalid windows instead.
        guard rr.count >= HealthConstants.minimumRRIntervals, rr.allSatisfy({ $0.isFinite && $0 >= 250 && $0 <= 2000 }) else { return nil }
        return sqrt(zip(rr, rr.dropFirst()).map { pow($1 - $0, 2) }.reduce(0,+) / Double(rr.count - 1))
    }
    static func minuteSeries(history: [Sample], live: [MinuteHR], workoutReadings: [WorkoutReading], details: [Int64: HistoryMinute] = [:], from: Date, to: Date) -> [MinuteHR?] {
        let start = from.timeIntervalSince1970, end = to.timeIntervalSince1970
        guard start.isFinite, end.isFinite, end > start, end - start <= 366 * 86400,
              abs(start) < 1e12, abs(end) < 1e12 else { return [] }
        let first = Int64(floor(start / 60)), last = Int64(ceil(end / 60))
        var buckets: [Int64: [Int]] = [:]
        var seen = Set<String>()
        for sample in history {
            let time = sample.date.timeIntervalSince1970
            guard time.isFinite, time >= start, time < end, sample.bpm > 0, sample.bpm <= 300,
                  seen.insert(sample.id).inserted else { continue }
            buckets[Int64(floor(time / 60)), default: []].append(sample.bpm)
        }
        // Prefer original history, then persisted live aggregates, then workout fallback.
        // Never give a minute more weight merely because it has several source copies.
        var result: [Int64: MinuteHR] = [:]
        for minute in live where minute.count > 0 && minute.average.isFinite && minute.average > 0 && minute.average <= 300 {
            if minute.minute >= first && minute.minute < last { result[minute.minute] = minute }
        }
        var workoutBuckets: [Int64: [Int]] = [:]
        for sample in workoutReadings {
            let time = sample.date.timeIntervalSince1970
            guard time.isFinite, time >= start, time < end, sample.bpm > 0, sample.bpm <= 300 else { continue }
            workoutBuckets[Int64(floor(time / 60)), default: []].append(sample.bpm)
        }
        for (minute, values) in workoutBuckets where result[minute] == nil {
            result[minute] = aggregate(minute, values)
        }
        for (minute, values) in buckets {
            var value = aggregate(minute, values)
            value?.rmssd = result[minute]?.rmssd; value?.validRRCount = result[minute]?.validRRCount
            if let detail = details[minute] { value?.motion = detail.motion; value?.rrPairs = detail.rrPairs; value?.rrSumSquares = detail.rrSumSquares; value?.skinRaw = detail.skinRaw }
            result[minute] = value
        }
        return (first..<last).map { result[$0] }
    }
    static func aggregate(_ minute: Int64, _ values: [Int]) -> MinuteHR? {
        guard !values.isEmpty else { return nil }
        return MinuteHR(minute: minute, average: values.map(Double.init).reduce(0,+)/Double(values.count), minimum: values.min()!, maximum: values.max()!, count: values.count)
    }
}
