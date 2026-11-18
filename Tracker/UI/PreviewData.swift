#if DEBUG
import SwiftUI

/// Debug-only sample data so every screen can be seen without a band.
/// Enabled by launching with the `-previewData` argument. Never compiled into release builds.
/// Nothing here is persisted: workouts and samples are only placed in memory.
enum PreviewData {
    @MainActor static func apply(to store: DisplayStore, band: BandManager) {
        store.previewMode = true
        let now = Date()
        let calendar = Calendar.current
        let startOfDay = calendar.startOfDay(for: now)

        // Seed a live trace and keep a believable live heart rate flowing.
        var bpm = 72.0
        var points: [HRPoint] = []
        for i in stride(from: 360, through: 0, by: -1) {
            let date = now.addingTimeInterval(-Double(i) * 5)
            let phase = Double(i)
            let lift = max(0, 34 * exp(-pow((phase - 230) / 40, 2)))   // a short walk earlier
            bpm = 70 + lift + 3 * sin(phase / 7)
            points.append(HRPoint(date: date, bpm: Int(bpm.rounded())))
        }
        store.seedTrace(points)
        store.ingest(bpm: points.last?.bpm ?? 72, at: now)

        var tick = 0.0
        store.previewTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak store, weak band] _ in
            MainActor.assumeIsolated {
                guard let store, let band else { return }
                tick += 1
                let training = band.activeWorkout != nil && band.activeWorkout?.pausedAt == nil
                let base = training ? 150.0 + 12 * sin(tick / 25) : 72.0 + 4 * sin(tick / 9)
                let value = Int((base + Double.random(in: -1.5...1.5)).rounded())
                let date = Date()
                store.ingest(bpm: value, at: date)
                if training { band.activeWorkout?.readings.append(WorkoutReading(date: date, bpm: value)) }
            }
        }

        // Synced history for today.
        var history: [Sample] = []
        var t = startOfDay.addingTimeInterval(3600)
        while t < now {
            let hour = t.timeIntervalSince(startOfDay) / 3600
            let sleeping = hour < 7
            let value = sleeping ? 55 + 3 * sin(hour * 4) : 74 + 8 * sin(hour) + (abs(hour - 12.75) < 0.4 ? 40 : 0) + (abs(hour - 6.9) < 0.4 ? 78 : 0)
            history.append(Sample(id: UUID().uuidString, date: t, bpm: Int(value)))
            t.addTimeInterval(20)
        }
        band.samples = history

        // Today's workouts (in memory only).
        func readings(start: Date, minutes: Int, base: Int) -> [WorkoutReading] {
            (0..<(minutes * 12)).map { index in
                let progress = Double(index) / Double(minutes * 12)
                let ramp = min(1, progress * 6) * min(1, (1 - progress) * 8)
                let value = Double(base - 40) + 52 * ramp + 5 * sin(Double(index) / 9)
                return WorkoutReading(date: start.addingTimeInterval(Double(index) * 5), bpm: Int(value))
            }
        }
        let runStart = max(startOfDay.addingTimeInterval(6.7 * 3600), now.addingTimeInterval(-9 * 3600))
        var run = Workout(type: "Running")
        run.start = runStart; run.end = runStart.addingTimeInterval(24 * 60 + 10)
        run.readings = readings(start: runStart, minutes: 24, base: 156)
        var strength = Workout(type: "Strength")
        strength.start = max(startOfDay.addingTimeInterval(12.5 * 3600), now.addingTimeInterval(-3 * 3600))
        strength.end = strength.start.addingTimeInterval(45 * 60)
        strength.readings = readings(start: strength.start, minutes: 45, base: 128)
        band.workouts = [run, strength]
        store.workoutMetrics = [
            run.id: DisplayWorkoutMetrics(calories: 286, strain: 8.2),
            strength.id: DisplayWorkoutMetrics(calories: 126, strain: 6.1),
        ]
        store.activeMetrics = DisplayWorkoutMetrics(calories: 172, strain: 5.9)

        // Day summary.
        var hourly: [Double?] = [86, 84, 84, 85, 86, 88, 310, 120, 102, 104, 110, 118, 190, 150, 70]
        let currentHour = calendar.component(.hour, from: now)
        hourly = (0..<24).map { $0 <= currentHour && $0 < hourly.count ? hourly[$0] : nil }
        store.day = DisplayDay(
            strain: 11.4,
            recovery: DisplayRecovery(score: 74, band: .green),
            sleepPerformance: 0.86,
            calories: DisplayCalories(
                resting: 1430, active: 412, goal: 2600, hourly: hourly,
                sources: [
                    DisplayCalorieSource(id: "rest", name: "Resting", kcal: 1430, isResting: true),
                    DisplayCalorieSource(id: "run", name: "Running", kcal: 286),
                    DisplayCalorieSource(id: "str", name: "Strength", kcal: 126),
                ]))

        // Last night, as the sleep engine would report it.
        let wake = startOfDay.addingTimeInterval(6.9 * 3600)
        let sequence: [(SleepStage, Double)] = [
            (.light, 20), (.deep, 35), (.light, 15), (.deep, 30), (.light, 20), (.rem, 15), (.awake, 5), (.light, 30),
            (.deep, 25), (.light, 25), (.rem, 25), (.light, 30), (.awake, 8), (.light, 35), (.rem, 28), (.light, 25),
            (.deep, 11), (.light, 28), (.rem, 30), (.awake, 11), (.light, 10), (.rem, 25),
        ]
        let total = sequence.reduce(0) { $0 + $1.1 } * 60
        var cursor = wake.addingTimeInterval(-total)
        let segments = sequence.map { stage, minutes -> DisplaySleepSegment in
            defer { cursor.addTimeInterval(minutes * 60) }
            return DisplaySleepSegment(stage: stage, start: cursor, end: cursor.addingTimeInterval(minutes * 60))
        }
        store.lastSleep = DisplaySleep(
            start: wake.addingTimeInterval(-total), end: wake,
            asleep: 7 * 3600 + 42 * 60, inBed: total, need: 8 * 3600 + 56 * 60, performance: 0.86,
            efficiency: 0.95, consistency: 0.81, segments: segments,
            sleepingHR: 54, hrv: 68, respiratoryRate: 14.8,
            needBaseline: 7 * 3600 + 50 * 60, needStrain: 36 * 60, needDebt: 30 * 60)

        // A pending auto-detected workout.
        let detectionStart = now.addingTimeInterval(-40 * 60)
        let trace = readings(start: detectionStart, minutes: 24, base: 156).map(\.point)
        store.detections = [
            DisplayDetection(
                id: "preview-detection", start: detectionStart, end: detectionStart.addingTimeInterval(24 * 60 + 10),
                guessedType: "Running", confidence: 0.82, avgHR: 152, maxHR: 171, calories: 286, strain: 8.2,
                trace: trace, zones: HRMath.timeInZones(trace, maxHR: ZoneConfig.maxHR)),
        ]
    }
}
#endif
