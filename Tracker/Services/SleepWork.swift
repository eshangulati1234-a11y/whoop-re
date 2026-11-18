import Foundation

/// Everything the overnight calculation needs, captured on the main thread so the work itself can run
/// on a background queue with its own database connection.
struct SleepWorkInput {
    var url: URL
    var now: Date
    var calendar: Calendar
    var profile: UserProfile?
    var zones: ZoneConfiguration?
    var readings: [WorkoutReading]
    var corrections: [String: DateInterval]
    var napDecisions: [String: Bool]
}

struct SleepWorkOutput {
    /// Nights by wake day, the last 40 days.
    var known: [Int: SleepSession]
    /// Today's night did not exist before this run.
    var newlyFound: Bool
    var failures: [String]
}

/// Finds and scores nights and naps, and saves them. Runs off the main thread.
enum SleepWork {
    static func run(_ input: SleepWorkInput) throws -> SleepWorkOutput {
        let store = try HistoryStore(url: input.url)
        let context = Context(input: input, store: store)
        return context.run()
    }

    private struct Context {
        let input: SleepWorkInput
        let store: HistoryStore
        var calendar: Calendar { input.calendar }

        func run() -> SleepWorkOutput {
            let now = input.now
            let today = dayNumber(now)
            var failures: [String] = []
            var known: [Int: SleepSession] = [:]
            for item in (try? store.sleeps(fromDay: today - 40, toDay: today)) ?? [] { known[item.wakeDay] = item.session }
            let todayStart = calendar.startOfDay(for: now)
            let newlyFound = known[today] == nil

            // Recent nights are always refreshed; older ones only when they were never computed.
            for offset in stride(from: 28, through: 0, by: -1) {
                let wakeDay = today - offset
                guard offset <= 2 || known[wakeDay] == nil else { continue }
                guard let dayStart = calendar.date(byAdding: .day, value: -offset, to: todayStart), var session = night(ending: dayStart, now: now) else { continue }
                session = complete(session, wakeDay: wakeDay, dayStart: dayStart, known: known)
                known[wakeDay] = session
                do { try store.saveSleep(session, wakeDay: wakeDay) } catch { failures.append(error.localizedDescription) }
            }
            if let failure = detectNaps(today: today, known: known, now: now) { failures.append(failure) }
            return SleepWorkOutput(known: known, newlyFound: newlyFound, failures: failures)
        }

        func dayNumber(_ date: Date) -> Int {
            let start = calendar.startOfDay(for: date)
            return Int(((start.timeIntervalSince1970 + Double(calendar.timeZone.secondsFromGMT(for: start))) / 86400).rounded())
        }
        func firstMinute(_ date: Date) -> Int64 { Int64(floor(date.timeIntervalSince1970 / 60)) }

        func minuteSeries(from: Date, to: Date) -> [MinuteHR?] {
            guard to > from else { return [] }
            let history = (try? store.samples(from: from, to: to)) ?? []
            let live = (try? store.liveMinutes(from: from, to: to)) ?? []
            let details = (try? store.historyMinutes(from: from, to: to)) ?? [:]
            return HRTimeline.minuteSeries(history: history, live: live, workoutReadings: input.readings, details: details, from: from, to: to)
        }

        /// The night ending on `dayStart`, searched from 18:00 the day before to 14:00.
        func night(ending dayStart: Date, now: Date) -> SleepSession? {
            guard let previous = calendar.date(byAdding: .day, value: -1, to: dayStart),
                  let from = calendar.date(bySettingHour: HealthConstants.sleepWindowStartHour, minute: 0, second: 0, of: previous),
                  let windowEnd = calendar.date(bySettingHour: HealthConstants.sleepWindowEndHour, minute: 0, second: 0, of: dayStart) else { return nil }
            let to = min(windowEnd, now)
            guard to.timeIntervalSince(from) >= Double(HealthConstants.sleepMinimumMinutes) * 60 else { return nil }
            let series = minuteSeries(from: from, to: to)
            return SleepEngine.detect(series, firstMinute: firstMinute(from), daytimeBaseline: quietBaseline(day: previous))
        }

        /// Heart rate while awake and still (sitting, lying down watching TV), 08:00–21:00 the day before.
        /// Sleep is a drop below *this* level, not below the busy daytime average, so resting quietly
        /// is not mistaken for sleep. Falls back to the whole-day median when too few still minutes exist.
        func quietBaseline(day: Date) -> Double? {
            guard let dayFrom = calendar.date(bySettingHour: 8, minute: 0, second: 0, of: day),
                  let dayTo = calendar.date(bySettingHour: HealthConstants.quietBaselineEndHour, minute: 0, second: 0, of: day) else { return nil }
            return SleepEngine.quietBaseline(minuteSeries(from: dayFrom, to: dayTo))
        }

        /// Adds need, performance and consistency to a detected night.
        func complete(_ detected: SleepSession, wakeDay: Int, dayStart: Date, known: [Int: SleepSession]) -> SleepSession {
            var session = detected
            if let correction = input.corrections[String(detected.start.timeIntervalSince1970)] {
                let values = minuteSeries(from: correction.start, to: correction.end)
                session.start = correction.start; session.end = correction.end
                session.inBed = correction.duration; session.asleep = correction.duration; session.awake = 0
                session.coverage = CalibrationEngine.coverage(values)
                session.sleepingHR = Stats.median(values.compactMap { $0?.average }) ?? detected.sleepingHR
                session.stages = nil
            }
            var strain: Double?
            if let zones = input.zones, let previous = calendar.date(byAdding: .day, value: -1, to: dayStart) {
                strain = CalibrationEngine.score(minuteSeries(from: previous, to: dayStart), zones: zones)
            }
            let earlier = known.filter { $0.key < wakeDay }.sorted { $0.key < $1.key }.map(\.value)
            let shortfalls = earlier.compactMap { s in s.need.map { $0 - s.asleep } }
            let napSeconds = confirmedNaps(day: wakeDay - 1).reduce(0) { $0 + $1.asleep }
            let need = SleepEngine.need(baselineHours: input.profile?.sleepNeedHours, previousDayStrain: strain, recentShortfalls: shortfalls, napSeconds: napSeconds)
            session.needNap = need.nap
            session.need = need.total; session.needBaseline = need.baseline; session.needStrain = need.strain; session.needDebt = need.debt
            session.performance = SleepEngine.performance(asleep: session.asleep, need: need.total)
            let nights = earlier + [session]
            func minutes(_ date: Date, _ day: Date) -> Double { date.timeIntervalSince(day) / 60 }
            // Times are relative to the midnight that starts each night's wake day, approximated from the stored session end.
            let onsets = nights.map { s in minutes(s.start, calendar.startOfDay(for: s.end)) }
            let wakes = nights.map { s in minutes(s.end, calendar.startOfDay(for: s.end)) }
            session.consistency = SleepEngine.consistency(onsets: onsets, wakes: wakes)
            return session
        }

        func confirmedNaps(day: Int) -> [SleepSession] {
            ((try? store.document("naps:\(day)", as: [SleepSession].self)) ?? []).filter { nap in
                input.napDecisions[String(nap.start.timeIntervalSince1970)] ?? (nap.asleep >= Double(HealthConstants.napDirectMinutes) * 60)
            }
        }

        /// Daytime sleep outside the main night, for today and yesterday. Returns a failure message, if any.
        func detectNaps(today: Int, known: [Int: SleepSession], now: Date) -> String? {
            for offset in 0...1 {
                guard let dayStart = calendar.date(byAdding: .day, value: -offset, to: calendar.startOfDay(for: now)),
                      let from = calendar.date(bySettingHour: HealthConstants.napStartHour, minute: 0, second: 0, of: dayStart),
                      let windowEnd = calendar.date(bySettingHour: HealthConstants.napEndHour, minute: 0, second: 0, of: dayStart) else { continue }
                let to = min(windowEnd, now)
                guard to.timeIntervalSince(from) >= Double(HealthConstants.napMinimumMinutes) * 60 else { continue }
                var series = minuteSeries(from: from, to: to)
                if let main = known[today - offset] {
                    let low = Int64(main.start.timeIntervalSince1970 / 60), high = Int64(main.end.timeIntervalSince1970 / 60)
                    series = series.map { minute in minute.flatMap { $0.minute >= low && $0.minute < high ? nil : $0 } }
                }
                let found = SleepEngine.naps(series, firstMinute: firstMinute(from), daytimeBaseline: nil)
                do { try store.saveDocument(found, key: "naps:\(today - offset)") } catch { return error.localizedDescription }
            }
            return nil
        }
    }
}
