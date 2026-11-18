#if DEBUG
import Foundation

/// Debug-only: launch with `-demoHistory` to run the real engines over two weeks of synthetic
/// heart-rate history, held in a throwaway database. Nothing here exists in release builds.
enum DemoData {
    static var isEnabled: Bool { CommandLine.arguments.contains("-demoHistory") }
    private static var timer: Timer?

    @MainActor static func seed(band: BandManager, store: DisplayStore) {
        guard let database = band.storage else { return }
        let calendar = Calendar.current
        let now = Date()
        let todayStart = calendar.startOfDay(for: now)
        func noise(_ minute: Int, _ day: Int, _ spread: Double) -> Double { Double((minute &* 7919 &+ (day + 20) &* 104729) % 11 - 5) / 5 * spread }

        var samples: [Sample] = []
        let nights = Int(CommandLine.arguments.drop { $0 != "-demoNights" }.dropFirst().first ?? "") ?? 14
        for offset in stride(from: -nights, through: 0, by: 1) {
            guard let dayStart = calendar.date(byAdding: .day, value: offset, to: todayStart) else { continue }
            let bedtime = 23 * 60 + 15 + (offset * 13 % 25)   // minutes after midnight the night begins
            let wakeMinute = 7 * 60 + (offset * 7 % 20)
            for minute in 0..<1440 {
                let time = dayStart.addingTimeInterval(Double(minute) * 60)
                guard time < now.addingTimeInterval(-10 * 60) else { break }
                let asleep = minute < wakeMinute || minute >= bedtime
                let sinceBed = minute >= bedtime ? minute - bedtime : minute + (1440 - bedtime)
                var bpm: Double
                if asleep {
                    bpm = 54 + 3 * sin(Double(sinceBed) / 37) + (sinceBed < 150 ? -2 : 1) + noise(minute, offset, 1.5)
                    if (sinceBed >= 170 && sinceBed < 175) || (sinceBed >= 320 && sinceBed < 325) { bpm = 73 }
                } else {
                    bpm = 70 + 6 * sin(Double(minute) / 53) + noise(minute, offset, 3)
                    // Evening run on most past days.
                    if offset < 0, offset % 3 != 0, minute >= 17 * 60 + 30, minute < 18 * 60 + 5 { bpm = 148 + 8 * sin(Double(minute) / 4) + noise(minute, offset, 3) }
                }
                samples.append(Sample(id: "demo:\(offset):\(minute)", date: time, bpm: Int(bpm.rounded())))
            }
        }
        // An effort that finished about an hour ago, left for the detector to find.
        let effortStart = now.addingTimeInterval(-100 * 60)
        samples.removeAll { $0.date >= effortStart && $0.date < effortStart.addingTimeInterval(34 * 60) }
        for index in 0..<34 {
            let time = effortStart.addingTimeInterval(Double(index) * 60)
            samples.append(Sample(id: "demo:effort:\(index)", date: time, bpm: Int(150 + 9 * sin(Double(index) / 3) + noise(index, 99, 3))))
        }
        try? database.insertSamples(samples)
        band.samples = (try? database.recent()) ?? []
        band.lastSync = now.addingTimeInterval(-12 * 60)
        let stage = Int(CommandLine.arguments.drop { $0 != "-setupStage" }.dropFirst().first ?? "") ?? 5
        band.applyDebugSetup(stage)
        store.previewMode = true

        var tick = 0.0
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak band] _ in
            MainActor.assumeIsolated {
                guard let band else { return }
                tick += 1
                let training = band.activeWorkout != nil && band.activeWorkout?.pausedAt == nil
                let base = training ? 150.0 + 12 * sin(tick / 25) : 72.0 + 4 * sin(tick / 9)
                band.injectDemoReading(Int((base + Double.random(in: -1.5...1.5)).rounded()))
            }
        }
    }
}
#endif
