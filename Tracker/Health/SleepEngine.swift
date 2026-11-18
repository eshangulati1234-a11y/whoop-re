import Foundation

/// Heart-rate-only sleep estimate. Without motion data this finds the long stretch where
/// heart rate sits well below the daytime level; stages are a hypothesis, never a measurement.
enum SleepEngine {
    /// - Parameters:
    ///   - series: one slot per minute across the search window, `nil` where there is no data.
    ///   - firstMinute: Unix minute of `series[0]`.
    ///   - daytimeBaseline: median awake heart rate of the previous day. When `nil`, the 80th
    ///     percentile of the window stands in (the window is mostly sleep, so its median would be too low).
    static func detect(_ series: [MinuteHR?], firstMinute: Int64, daytimeBaseline: Double?) -> SleepSession? {
        detectAll(series, firstMinute: firstMinute, daytimeBaseline: daytimeBaseline).max { $0.inBed < $1.inBed }
    }

    /// Every sleep period in the window, oldest first. `detect` keeps the longest; naps use the shorter limits.
    static func detectAll(_ series: [MinuteHR?], firstMinute: Int64, daytimeBaseline: Double?,
                          minimumMinutes: Int = HealthConstants.sleepMinimumMinutes, holdMinutes: Int = HealthConstants.sleepHoldMinutes,
                          mergeGap: Int = HealthConstants.sleepMergeGapMinutes) -> [SleepSession] {
        let values = series.map { $0?.average }
        let known = values.compactMap { $0 }
        guard known.count >= minimumMinutes,
              let baseline = daytimeBaseline ?? Stats.percentile(known, 0.8) else { return [] }
        let threshold = baseline - HealthConstants.sleepDropBPM

        // Centred rolling median; `nil` where too little data surrounds the minute.
        let half = HealthConstants.sleepRollingMinutes / 2
        let rolling: [Double?] = values.indices.map { index in
            let window = values[max(0, index - half)..<min(values.count, index + half)].compactMap { $0 }
            return window.count >= 3 ? Stats.median(window) : nil
        }
        // Movement over the same window. Minutes without movement data count as still (older records).
        let motions = series.map { $0?.motion }
        let rollingMotion: [Double?] = motions.indices.map { index in
            let window = motions[max(0, index - half)..<min(motions.count, index + half)].compactMap { $0 }
            return window.count >= 3 ? Stats.median(window) : nil
        }
        // true = asleep-level (heart rate low and still), false = awake-level, nil = unknown.
        let low: [Bool?] = rolling.indices.map { index in
            rolling[index].map { $0 < threshold && (rollingMotion[index].map { $0 <= HealthConstants.sleepStillMotion } ?? true) }
        }
        let hold = holdMinutes

        func holds(from index: Int, _ wanted: Bool) -> Bool {
            guard index + hold <= low.count else { return false }
            let window = low[index..<(index + hold)]
            return !window.contains(!wanted) && window.compactMap({ $0 }).count >= hold / 2
        }
        // Collect asleep periods as half-open minute index ranges.
        var periods: [Range<Int>] = []
        var index = 0
        while index < low.count {
            guard low[index] == true, holds(from: index, true) else { index += 1; continue }
            var end = low.count
            var cursor = index + hold
            while cursor < low.count {
                if low[cursor] == false, holds(from: cursor, false) { end = cursor; break }
                cursor += 1
            }
            // Trim trailing unknown minutes: sleep cannot be claimed where nothing was measured.
            while end > index, low[end - 1] == nil { end -= 1 }
            periods.append(index..<end)
            index = max(end, index + 1)
        }
        guard !periods.isEmpty else { return [] }
        // Short awake stretches join neighbouring periods into one night.
        var merged: [Range<Int>] = []
        for period in periods {
            if let last = merged.last, period.lowerBound - last.upperBound < mergeGap {
                merged[merged.count - 1] = last.lowerBound..<period.upperBound
            } else { merged.append(period) }
        }
        return merged.filter { $0.count >= minimumMinutes }.compactMap { build($0, series: series, values: values, firstMinute: firstMinute) }
    }

    private static func build(_ night: Range<Int>, series: [MinuteHR?], values: [Double?], firstMinute: Int64) -> SleepSession? {
        let nightValues = values[night].compactMap { $0 }
        guard let sleepingMedian = Stats.median(nightValues) else { return nil }
        // Movement: gravity change well above this night's own typical level.
        let motions = series[night].compactMap { $0?.motion }
        let motionMedian = Stats.median(motions)
        func moving(_ minute: Int) -> Bool {
            guard let motionMedian, let motion = series[minute]?.motion else { return false }
            return motion > max(HealthConstants.motionFloor, HealthConstants.motionMultiple * motionMedian)
        }
        // Awakenings: several minutes in a row well above the sleeping level, or in continuous movement.
        var awake = Array(repeating: false, count: night.count)
        var run: [Int] = []
        var bouts = 0
        func flush() { if run.count >= HealthConstants.awakeBoutMinutes { for offset in run { awake[offset] = true }; bouts += 1 }; run = [] }
        for (offset, minute) in night.enumerated() {
            let raised = values[minute].map { $0 > sleepingMedian + HealthConstants.awakeRiseBPM } ?? false
            if raised || moving(minute) { run.append(offset) } else { flush() }
        }
        flush()

        let asleepValues = night.enumerated().compactMap { offset, minute in awake[offset] ? nil : values[minute] }
        guard let sleepingHR = Stats.mean(asleepValues) else { return nil }
        // Asleep minutes only; awake minutes become gaps so they never feed resting HR or HRV.
        let asleepSeries: [MinuteHR?] = night.enumerated().map { offset, minute in awake[offset] ? nil : series[minute] }
        let lowest = CalibrationEngine.restingHR(asleepSeries.compactMap { $0 }) ?? sleepingHR
        let coverage = Double(nightValues.count) / Double(night.count)
        let awakeMinutes = awake.filter { $0 }.count
        func date(_ minuteIndex: Int) -> Date { Date(timeIntervalSince1970: Double(firstMinute + Int64(minuteIndex)) * 60) }
        let stageList = coverage >= HealthConstants.stageMinimumCoverage ? stages(values: Array(values[night]), awake: awake, start: date(night.lowerBound)) : nil
        let skin = Stats.median(night.enumerated().compactMap { offset, minute in awake[offset] ? nil : series[minute]?.skinRaw })
        let asleep = Double(night.count - awakeMinutes) * 60
        var session = SleepSession(
            start: date(night.lowerBound), end: date(night.upperBound),
            inBed: Double(night.count) * 60, asleep: asleep, awake: Double(awakeMinutes) * 60,
            stages: stageList, sleepingHR: sleepingHR, lowestHR: lowest, rmssd: HRTimeline.nightRMSSD(asleepSeries[...]), coverage: coverage)
        session.disturbances = bouts
        session.skinRaw = skin
        session.noData = Double(night.count - nightValues.count) * 60
        if let stageList {
            session.cycles = cycles(stageList)
            let restorative = stageList.filter { $0.stage == .deep || $0.stage == .rem }.reduce(0.0) { $0 + $1.end.timeIntervalSince($1.start) }
            session.restorativeShare = asleep > 0 ? min(1, restorative / asleep) : nil
        }
        return session
    }

    /// Sleep cycles: each deep stage followed later by REM.
    static func cycles(_ segments: [SleepSegment]) -> Int {
        var count = 0; var seenDeep = false
        for segment in segments {
            if segment.stage == .deep { seenDeep = true }
            else if segment.stage == .rem, seenDeep { count += 1; seenDeep = false }
        }
        return count
    }

    /// Naps in a daytime window. Sleep already attributed to the main night should be passed as `nil` minutes.
    static func naps(_ series: [MinuteHR?], firstMinute: Int64, daytimeBaseline: Double?) -> [SleepSession] {
        detectAll(series, firstMinute: firstMinute, daytimeBaseline: daytimeBaseline,
                  minimumMinutes: HealthConstants.napMinimumMinutes, holdMinutes: HealthConstants.napHoldMinutes, mergeGap: 20)
            .filter { $0.asleep >= Double(HealthConstants.napMinimumMinutes) * 60 && $0.asleep <= Double(HealthConstants.napMaximumMinutes) * 60 }
            // Heart rate alone cannot tell a nap from sitting quietly, so a nap needs measured stillness
            // on fixed limits and a real heart-rate drop from just before it.
            .filter { nap in
                let first = Int(nap.start.timeIntervalSince1970 / 60 - Double(firstMinute)), last = Int(nap.end.timeIntervalSince1970 / 60 - Double(firstMinute))
                guard first >= 0, last <= series.count, last > first else { return false }
                return napIsStill(series[first..<last].map { $0?.motion }) && napDropped(nap, before: series[max(0, first - HealthConstants.napLeadMinutes)..<first])
            }
            .map { var nap = $0; nap.isNap = true; nap.stages = nil; return nap }
    }

    /// Median heart rate while awake and still. `nil` when fewer than an hour of still minutes exist;
    /// then the median of every minute stands in, and with less than an hour of data, nothing.
    static func quietBaseline(_ day: [MinuteHR?]) -> Double? {
        let minutes = day.compactMap { $0 }
        let quiet = minutes.filter { ($0.motion.map { $0 <= HealthConstants.stillMotion }) ?? false }.map(\.average)
        if quiet.count >= HealthConstants.quietBaselineMinutes { return Stats.median(quiet) }
        return minutes.count >= HealthConstants.quietBaselineMinutes ? Stats.median(minutes.map(\.average)) : nil
    }

    /// At least 80% of the nap measured, most minutes still, and no sustained movement.
    static func napIsStill(_ motions: [Double?]) -> Bool {
        let measured = motions.compactMap { $0 }
        guard !motions.isEmpty, Double(measured.count) >= 0.8 * Double(motions.count) else { return false }
        guard Double(measured.filter { $0 <= HealthConstants.napStillMotion }.count) >= HealthConstants.napStillShare * Double(measured.count) else { return false }
        var run = 0
        for motion in motions {
            if let motion, motion > HealthConstants.napMoveMotion { run += 1; if run >= HealthConstants.napMoveRunMinutes { return false } } else { run = 0 }
        }
        return true
    }
    /// Heart rate during the nap sits clearly below the time just before it. Without enough lead-in data, the
    /// detector's own baseline drop stands.
    static func napDropped(_ nap: SleepSession, before: ArraySlice<MinuteHR?>) -> Bool {
        let lead = before.compactMap { $0?.average }
        guard lead.count >= 20, let median = Stats.median(lead) else { return true }
        return nap.sleepingHR <= median - HealthConstants.napDropBPM
    }

    enum SkinState: String { case typical = "Typical", above = "Above your usual", below = "Below your usual" }
    /// Skin temperature is a raw ADC value, so only the change from the user's own nights is meaningful.
    static func skinState(tonight: Double, history: [Double]) -> SkinState? {
        guard history.count >= 7, let mean = Stats.mean(history), let deviation = Stats.deviation(history) else { return nil }
        let spread = max(deviation, 1)
        return tonight > mean + 2 * spread ? .above : tonight < mean - 2 * spread ? .below : .typical
    }

    /// Experimental: lowest, steadiest stretches → deep; most variable → REM; the rest → light.
    private static func stages(values: [Double?], awake: [Bool], start: Date) -> [SleepSegment] {
        let count = values.count
        func window(_ index: Int) -> [Double] { values[max(0, index - 5)..<min(count, index + 6)].compactMap { $0 } }
        let smooth = (0..<count).map { Stats.mean(window($0)) }
        let spread = (0..<count).map { Stats.deviation(window($0)) }
        let asleep = (0..<count).filter { !awake[$0] }
        let deepCut = Stats.percentile(asleep.compactMap { smooth[$0] }, 0.3) ?? 0
        let calmCut = Stats.median(asleep.compactMap { spread[$0] }) ?? 0
        let remCut = Stats.percentile(asleep.compactMap { spread[$0] }, 0.75) ?? .infinity
        var kinds: [SleepStageKind] = (0..<count).map { index in
            if awake[index] { return .awake }
            guard let level = smooth[index], let variation = spread[index] else { return .light }
            if level <= deepCut && variation <= calmCut { return .deep }
            if variation >= remCut && variation > 0 { return .rem }
            return .light
        }
        // Majority filter so single noisy minutes do not flip the stage (awakenings are kept as detected).
        let radius = 7
        let raw = kinds
        for index in 0..<count where raw[index] != .awake {
            var votes: [SleepStageKind: Int] = [:]
            for neighbour in max(0, index - radius)...min(count - 1, index + radius) where raw[neighbour] != .awake { votes[raw[neighbour], default: 0] += 1 }
            if let winner = votes.max(by: { $0.value < $1.value })?.key { kinds[index] = winner }
        }
        // Absorb any fragment still shorter than the minimum into the stage before it, until stable.
        var changed = true
        while changed {
            changed = false
            var index = 0
            while index < count {
                var end = index
                while end < count, kinds[end] == kinds[index] { end += 1 }
                if kinds[index] != .awake, end - index < HealthConstants.stageMinimumMinutes {
                    let replacement: SleepStageKind = index > 0 && kinds[index - 1] != .awake ? kinds[index - 1] : (end < count && kinds[end] != .awake ? kinds[end] : .light)
                    if replacement != kinds[index] { for position in index..<end { kinds[position] = replacement }; changed = true }
                }
                index = end
            }
        }
        var segments: [SleepSegment] = []
        var index = 0
        while index < count {
            var end = index
            while end < count, kinds[end] == kinds[index] { end += 1 }
            segments.append(SleepSegment(stage: kinds[index], start: start.addingTimeInterval(Double(index) * 60), end: start.addingTimeInterval(Double(end) * 60)))
            index = end
        }
        return segments
    }

    struct Need: Equatable { var baseline: TimeInterval; var strain: TimeInterval; var debt: TimeInterval; var nap: TimeInterval = 0; var total: TimeInterval { max(0, baseline + strain + debt - nap) } }

    /// - Parameter recentShortfalls: `need − asleep` for the most recent nights (negative values count as zero).
    static func need(baselineHours: Double?, previousDayStrain: Double?, recentShortfalls: [TimeInterval], napSeconds: TimeInterval = 0) -> Need {
        let baseline = (baselineHours ?? HealthConstants.sleepNeedBaselineHours) * 3600
        let strain = max(0, previousDayStrain ?? 0) * HealthConstants.sleepNeedStrainMinutes * 60
        let shortfall = recentShortfalls.suffix(HealthConstants.sleepDebtNights).map { max(0, $0) }.reduce(0, +)
        return Need(baseline: baseline, strain: strain, debt: min(HealthConstants.sleepDebtCap, shortfall * HealthConstants.sleepDebtShare), nap: min(HealthConstants.napNeedCap, max(0, napSeconds)))
    }

    static func performance(asleep: TimeInterval, need: TimeInterval) -> Double? {
        need > 0 ? min(1, max(0, asleep / need)) : nil
    }

    /// 0...100 from how much bed and wake clock times moved across recent nights. Needs two nights.
    /// Times are minutes relative to local midnight of the wake day (onset before midnight is negative).
    static func consistency(onsets: [Double], wakes: [Double]) -> Double? {
        let recentOnsets = Array(onsets.suffix(HealthConstants.consistencyNights)), recentWakes = Array(wakes.suffix(HealthConstants.consistencyNights))
        guard recentOnsets.count >= 2, recentOnsets.count == recentWakes.count,
              let onsetMean = Stats.mean(recentOnsets), let wakeMean = Stats.mean(recentWakes) else { return nil }
        let deviations = recentOnsets.map { abs($0 - onsetMean) } + recentWakes.map { abs($0 - wakeMean) }
        let average = deviations.reduce(0, +) / Double(deviations.count)
        return min(100, max(0, 100 * (1 - average / HealthConstants.consistencyZeroMinutes)))
    }
}
