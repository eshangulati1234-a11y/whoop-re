import Foundation

/// Heart-rate-only workout detection over a per-minute series. Works the same on live
/// minutes and on synced history; re-running over the same data gives the same windows.
enum ActivityDetector {
    struct Candidate: Equatable {
        /// Minute index (Unix seconds / 60) of the first and last working minute.
        var startMinute: Int64
        var endMinute: Int64
        var average: Double
        var maximum: Int
        var guessedType: String
        var confidence: Double
        /// The series ended while the effort was still going.
        var isOpen: Bool
        var start: Date { Date(timeIntervalSince1970: Double(startMinute) * 60) }
        /// End of the last working minute.
        var end: Date { Date(timeIntervalSince1970: Double(endMinute + 1) * 60) }
        var minutes: Int { Int(endMinute - startMinute) + 1 }
    }

    static func detect(_ series: [MinuteHR?], firstMinute: Int64, maxHR: Int) -> [Candidate] {
        guard maxHR > 0, !series.isEmpty else { return [] }
        let threshold = HealthConstants.detectionThreshold * Double(maxHR)
        func working(_ index: Int) -> Bool { series[index].map { $0.average >= threshold } ?? false }
        var result: [Candidate] = []
        var start: Int?, lastWorking = 0, belowRun = 0, idleRun = 0

        func close(open: Bool) {
            guard let from = start else { return }
            if lastWorking - from + 1 >= HealthConstants.detectionMinimumMinutes {
                result.append(candidate(series, from: from, to: lastWorking, firstMinute: firstMinute, maxHR: maxHR, open: open))
            }
            start = nil
        }
        for index in series.indices {
            if start == nil {
                let lower = max(0, index - HealthConstants.detectionStartWindow + 1)
                let window = lower...index
                guard working(index), window.filter(working).count >= HealthConstants.detectionStartHits else { continue }
                start = window.first(where: working); lastWorking = index; belowRun = 0; idleRun = 0
            } else if working(index) {
                lastWorking = index; belowRun = 0; idleRun = 0
            } else {
                idleRun += 1
                if series[index] != nil { belowRun += 1 }
                if belowRun >= HealthConstants.detectionEndBelowMinutes || idleRun >= HealthConstants.detectionEndGapMinutes { close(open: false) }
            }
        }
        close(open: true)
        return result
    }

    private static func candidate(_ series: [MinuteHR?], from: Int, to: Int, firstMinute: Int64, maxHR: Int, open: Bool) -> Candidate {
        let minutes = series[from...to].compactMap { $0 }
        let averages = minutes.map(\.average)
        let average = Stats.mean(averages) ?? 0
        let ratio = average / Double(maxHR)
        // Mean minute-to-minute change: steady efforts are low, interval-like efforts are high.
        let variability = Stats.mean(zip(averages, averages.dropFirst()).map { abs($1 - $0) }) ?? 0
        let type: String, confidence: Double
        if variability >= 8 { type = "Strength"; confidence = 0.5 }
        else if ratio >= 0.70 { type = "Running"; confidence = min(0.9, 0.55 + (ratio - 0.70) * 2) }
        else if ratio < 0.65 { type = "Walking"; confidence = 0.5 }
        else { type = "Other"; confidence = 0.3 }
        return Candidate(startMinute: firstMinute + Int64(from), endMinute: firstMinute + Int64(to), average: average,
                         maximum: minutes.map(\.maximum).max() ?? 0, guessedType: type, confidence: confidence, isOpen: open)
    }

    /// Share of `a` covered by `b`, 0...1.
    static func overlapShare(_ aStart: Date, _ aEnd: Date, _ bStart: Date, _ bEnd: Date) -> Double {
        let length = aEnd.timeIntervalSince(aStart)
        guard length > 0 else { return 0 }
        return max(0, min(aEnd, bEnd).timeIntervalSince(max(aStart, bStart))) / length
    }

    /// Merge fresh candidates into what is already stored.
    /// - A candidate mostly covered by a saved workout is dropped.
    /// - A candidate overlapping a stored detection updates it only while that one is pending; confirmed and
    ///   dismissed windows are never re-detected.
    /// Returns the detections to insert or update.
    static func reconcile(_ candidates: [Candidate], existing: [DetectedActivity], workouts: [(start: Date, end: Date)]) -> [DetectedActivity] {
        var changes: [DetectedActivity] = []
        for candidate in candidates {
            if workouts.contains(where: { overlapShare(candidate.start, candidate.end, $0.start, $0.end) > HealthConstants.detectionOverlapShare }) { continue }
            if let match = existing.first(where: { overlapShare(candidate.start, candidate.end, $0.start, $0.end) > 0 || overlapShare($0.start, $0.end, candidate.start, candidate.end) > 0 }) {
                guard match.status == .pending, match.start != candidate.start || match.end != candidate.end || match.isOpen != candidate.isOpen else { continue }
                var updated = match
                updated.start = min(match.start, candidate.start); updated.end = max(match.end, candidate.end)
                updated.isOpen = candidate.isOpen; updated.guessedType = candidate.guessedType; updated.confidence = candidate.confidence
                changes.append(updated)
            } else {
                changes.append(DetectedActivity(id: "det-\(candidate.startMinute)", start: candidate.start, end: candidate.end,
                                                guessedType: candidate.guessedType, confidence: candidate.confidence, status: .pending, isOpen: candidate.isOpen))
            }
        }
        return changes
    }
}
