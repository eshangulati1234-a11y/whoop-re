import Foundation
import SQLite3

func check(_ condition: @autoclosure () -> Bool, _ message: String) { precondition(condition(), message) }
check(FrameDecoder.crc32(Array("123456789".utf8)) == 0xcbf43926, "CRC32 known vector")
check(FrameDecoder.crc8(Array("123456789".utf8)) == 0xf4, "CRC8 known vector")
let helloHex = HistoryProtocol.command(.hello, sequence: 0).map { String(format: "%02x", $0) }.joined()
check(helloHex == "aa0800a823002300ada86a2d", "Reference hello wire fixture")
let alarmHex = HistoryProtocol.command(.alarm, sequence: 3).map { String(format: "%02x", $0) }.joined()
check(alarmHex == "aa0800a823034301c54dd63d", "Reference alarm revision byte")
let packet = HistoryProtocol.command(.hello, sequence: 1)
for split in 0...packet.count {
    var decoder = FrameDecoder()
    let frames = decoder.append(Array(packet.prefix(split))) + decoder.append(Array(packet.dropFirst(split)))
    check(frames == [[0x23, 1, 0x23, 0]], "Fragmentation")
}
var decoder = FrameDecoder()
var broken = packet; broken[5] ^= 1
check(decoder.append(broken + packet).count == 1, "CRC rejection and recovery")
let embedded = HistoryProtocol.frame([0x2f, 0xaa, 0xaa, 0xaa])
check(decoder.append(embedded).first == [0x2f, 0xaa, 0xaa, 0xaa], "Embedded SOF")
var record = Array(repeating: UInt8(0), count: 96)
record[0] = 0x2f; record[1] = 24; record[3] = 7; record[17] = 72
let epoch: UInt32 = 1_750_000_000
for i in 0..<4 { record[7+i] = UInt8(truncatingIfNeeded: epoch >> (8*i)) }
check(HistoryProtocol.sample(record, device: "test")?.bpm == 72, "Historical heart rate")
check(HistoryProtocol.sample(Array(record.prefix(18)), device: "test") == nil, "Truncated record")
let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
defer { for suffix in ["", "-wal", "-shm"] { try? FileManager.default.removeItem(atPath: url.path + suffix) } }
var store: HistoryStore? = try HistoryStore(url: url)
try store!.persist([record, record], device: "test")
check(try! store!.recent().count == 1, "Duplicate batch")
store = nil
store = try HistoryStore(url: url)
check(try! store!.recent().count == 1, "Durable across reopen")
try store!.persist([record], device: "test")
check(try! store!.recent().count == 1, "Interrupted transfer replay")
check(HistoryProtocol.token([0x31,0,2]) == nil, "Truncated ACK token")
try store!.replaySavedFrames()
check(try! store!.recent().count == 1, "Saved-frame replay remains idempotent")
check(try! store!.diagnostics().contains("Historical data 0x2F"), "Persisted packet type diagnostics")
let logs = (0..<256).map { sequence -> [UInt8] in [0x32, UInt8(sequence)] + Array(repeating: 0, count: 62) }
try store!.persist(logs, device: "test")
let report = try store!.diagnostics()
check(report.contains("Historical data 0x2F"), "Console logs cannot hide historical records")
check(report.contains("Console log 0x32 · 64–64 bytes · 256 saved"), "Console sequence aggregation")
check(report.contains("decoded HR"), "History example classification")
check(HistoryProtocol.rejectionReason(Array(record.prefix(24))) == "unsupported record length", "Explain decoder rejection")
try store!.persist([[0x24, 1, 0x22, 0x00, 0x12, 0x34, 0, 0], [0x31, 2, 3, 0]], device: "test")
let detailedReport = try store!.diagnostics()
check(detailedReport.contains("Data-range response hex / bytes: 2401220012340000 · 8"), "Data-range evidence is visible")
check(detailedReport.contains("Sync marker subtype: 03 · 1"), "Completion subtype grouping")
check(detailedReport.contains("Completion marker hex / bytes: 31020300 · 4"), "Completion evidence is visible")
let console = [UInt8(0x32), 0x23, 0, 1] + Array("Flash: RTC timestamp is invalid; not saving data to flash.".utf8)
try store!.persist([console], device: "test")
check(HistoryStore.consoleText(console).contains("RTC timestamp is invalid"), "Decode printable console evidence")
check(try! store!.diagnostics().contains("Clock/flash console evidence: Flash:"), "Surface relevant device errors")
check(HistoryProtocol.clockBody(seconds: 0x12345678) == [0x78,0x56,0x34,0x12,1], "Clock little-endian commit payload")
check(HistoryProtocol.clockResponse([0x24,0x7f,0x0b,0,1,0x78,0x56,0x34,0x12])?.timeIntervalSince1970 == Double(0x12345678), "Clock read-back")
check(HistoryProtocol.clockResponse([0x24,0,0x0b,0]) == nil, "Truncated clock response")
var recoveryDecoder = FrameDecoder()
var falseFrame = HistoryProtocol.frame(Array(repeating: 0, count: 40))
falseFrame.replaceSubrange(8..<(8 + packet.count), with: packet)
check(recoveryDecoder.append(falseFrame).contains([0x23,1,0x23,0]), "False valid-length header must not swallow a valid frame")
check(HeartRateReading.parse([0x10,60,0,4])?.rrMilliseconds == [1000], "RR tick conversion")
check(HeartRateReading.parse([1,44,1])?.bpm == 300, "16-bit HR")
check(HeartRateReading.parse([0x10,60,1]) == nil, "Reject truncated RR")
check(HeartRateReading.parse([4,60]) == nil, "Reject no-contact measurement")
var liveFrame = Array(repeating: UInt8(0), count: 20)
liveFrame[0] = 0x28; liveFrame[8] = 77
check(HeartRateReading.proprietary(liveFrame)?.bpm == 77, "Proprietary HR offset")
liveFrame[18] = 1
check(HeartRateReading.proprietary(liveFrame) == nil, "Ignore off-wrist proprietary HR")
check(HeartRateReading.proprietary([0x28,1]) == nil, "Reject truncated live frame")
var rawLive = Array(repeating: UInt8(0), count: 1928)
rawLive[0] = 0x2b; rawLive[1] = 10; rawLive[17] = 83
check(HeartRateReading.proprietary(rawLive)?.bpm == 83, "R10 raw live HR")
let profile = UserProfile(ageYears: 30, weightKg: 75, heightCm: 180, sex: .male)
check(profile.validationError == nil, "Valid profile")
let restoredProfile = try JSONDecoder().decode(UserProfile.self, from: JSONEncoder().encode(profile))
check(restoredProfile == profile, "Profile persistence round trip")
check(UserProfile(ageYears: 0, weightKg: 75, heightCm: 180, sex: .male).validationError != nil, "Invalid profile blocked")
let t0 = Date(timeIntervalSince1970: 1_750_000_020)
let timelineSamples = [Sample(id: "a",date: t0,bpm: 80),Sample(id: "a",date: t0,bpm: 80),Sample(id: "b",date: t0.addingTimeInterval(120),bpm: 100)]
let series = HRTimeline.minuteSeries(history: timelineSamples,live: [],workoutReadings: [WorkoutReading(date:t0,bpm:200)],from:t0,to:t0.addingTimeInterval(180))
check(series.count == 3 && series[1] == nil, "Timeline preserves gaps")
check(series[0]?.average == 80 && series[0]?.count == 1, "No duplicate source weighting")
check(HRTimeline.minuteSeries(history: [], live: [], workoutReadings: [], from: t0, to: t0.addingTimeInterval(-1)).isEmpty, "Reversed range")
check(HRTimeline.rmssd(Array(repeating:800,count:19)) == nil, "Insufficient RR")
check(HRTimeline.rmssd(Array(repeating:800,count:20)) == 0, "Constant RR")
check(HRTimeline.rmssd(Array(repeating:Double.nan,count:20)) == nil, "NaN RR rejected")
let liveMinute = MinuteHR(minute:Int64(t0.timeIntervalSince1970/60),average:80,minimum:70,maximum:90,count:10)
try store!.saveLiveMinute(liveMinute); try store!.saveLiveMinute(liveMinute)
check(try! store!.liveMinutes(from:t0,to:t0.addingTimeInterval(60)).count == 1, "Idempotent minute flush")
check(try! store!.recent().count == 1, "Migration preserves sample history")
print("Protocol, persistence, profile and timeline checks passed")

check(Zones.maximum(profile) == 187, "Tanaka maximum")
check(Zones.zone(bpm: 70 + 0.6 * 117, profile: profile) == 2, "Exact reserve zone boundary (40/60/70/80/90 of reserve, resting 70 until measured)")
check(Zones.zone(bpm: 70 + 0.39 * 117, profile: profile) == nil && Zones.zone(bpm: 70 + 0.4 * 117, profile: profile) == 1, "Zone 1 starts at 40% of reserve")
check(Zones.zone(bpm: .nan, profile: profile) == nil, "Reject NaN zone")
let training = (0..<30).map { i -> MinuteHR? in MinuteHR(minute:Int64(i),average:187*0.75,minimum:140,maximum:141,count:60) }
check(StrainEngine.score(training,profile:profile) == 5.4, "Edwards load 60 mapping with reserve zones")
check(StrainEngine.score([],profile:profile) == nil, "Missing data is not zero strain")
check(CalorieEngine.bmr(profile) == 1730, "Mifflin BMR")
check(CalorieEngine.estimate([],profile:profile,elapsedMinutes:60)?.active == 0, "Gap energy resting only")
check(CalorieEngine.estimate([],profile:profile,elapsedMinutes:.infinity) == nil, "Reject infinite time")
print("Zone, strain and energy adversarial checks passed")

// MARK: Detection, sleep, recovery, storage v3, sync policy
func makeSeries(_ segments: [(Int, Double)], first: Int64 = 1_000_000) -> [MinuteHR?] {
    var minute = first
    var result: [MinuteHR?] = []
    for (count, bpm) in segments {
        for _ in 0..<count {
            result.append(bpm <= 0 ? nil : MinuteHR(minute: minute, average: bpm, minimum: Int(bpm), maximum: Int(bpm), count: 60)); minute += 1
        }
    }
    return result
}
let maxHR = Zones.maximum(profile)
let run = ActivityDetector.detect(makeSeries([(5, 100), (20, 140), (5, 100)]), firstMinute: 1_000_000, maxHR: maxHR)
check(run.count == 1, "Run detected once")
check(abs(Int(run[0].startMinute) - 1_000_005) <= 1 && abs(run[0].minutes - 20) <= 1, "Run bounds within a minute")
check(run[0].guessedType == "Running" && !run[0].isOpen, "Steady vigorous effort guessed as running")
check(ActivityDetector.detect(makeSeries([(20, 80), (6, 140), (20, 80)]), firstMinute: 1_000_000, maxHR: maxHR).isEmpty, "Stair climb ignored")
check(ActivityDetector.detect(makeSeries([(5, 100), (15, 140)]), firstMinute: 1_000_000, maxHR: maxHR).first?.isOpen == true, "Ongoing effort stays open")
check(ActivityDetector.detect(makeSeries([(5, 140), (4, 0), (5, 140), (11, 0)]), firstMinute: 1_000_000, maxHR: maxHR).count == 1, "Short gap does not split a workout")
check(ActivityDetector.detect([], firstMinute: 0, maxHR: maxHR).isEmpty, "Empty series")
let stored = ActivityDetector.reconcile(run, existing: [], workouts: [])
check(stored.count == 1 && stored[0].status == .pending, "New detection is pending")
check(ActivityDetector.reconcile(run, existing: stored, workouts: []).isEmpty, "Re-running does not duplicate")
check(ActivityDetector.reconcile(run, existing: [], workouts: [(run[0].start.addingTimeInterval(60), run[0].end)]).isEmpty, "Manual workout suppresses detection")
var dismissed = stored[0]; dismissed.status = .dismissed
check(ActivityDetector.reconcile(run, existing: [dismissed], workouts: []).isEmpty, "Dismissed window never re-detected")

// A night: evening 70, asleep 55 for 7 h with two 5-minute awakenings, then 70.
let nightStart: Int64 = 2_000_000
let night = makeSeries([(300, 70), (100, 55), (5, 72), (150, 55), (5, 72), (165, 55), (475, 70)], first: nightStart)
let sleep = SleepEngine.detect(night, firstMinute: nightStart, daytimeBaseline: 70)!
check(abs(sleep.start.timeIntervalSince1970 / 60 - Double(nightStart + 300)) <= 5, "Sleep onset within 5 minutes")
check(abs(sleep.end.timeIntervalSince1970 / 60 - Double(nightStart + 725)) <= 5, "Wake within 5 minutes")
check(abs(sleep.awake - 600) <= 120, "Two awakenings found")
check(sleep.stages != nil && sleep.coverage > 0.99, "Full coverage gives stage hypothesis")
check(sleep.stages!.allSatisfy { $0.stage == .awake || $0.end.timeIntervalSince($0.start) >= 300 }, "No sleep stage shorter than 5 minutes")
check(sleep.sleepingHR < 58 && sleep.lowestHR <= 56, "Sleeping heart rate")
var sparse = night
for index in stride(from: 300, to: 725, by: 2) { sparse[index] = nil }
let sparseSleep = SleepEngine.detect(sparse, firstMinute: nightStart, daytimeBaseline: 70)
check(sparseSleep != nil && sparseSleep!.stages == nil, "Low coverage returns no stages")
check(SleepEngine.detect(makeSeries([(1200, 70)], first: nightStart), firstMinute: nightStart, daytimeBaseline: 70) == nil, "No dip means no sleep")
check(SleepEngine.detect(makeSeries([(50, 55)], first: nightStart), firstMinute: nightStart, daytimeBaseline: 70) == nil, "Too little data")
let need = SleepEngine.need(baselineHours: nil, previousDayStrain: 10, recentShortfalls: [3600, 0, 7200])
check(need.baseline == 27000 && need.strain == 1800 && need.debt == 5400 && need.total == 34200, "Sleep need arithmetic")
check(SleepEngine.need(baselineHours: 8, previousDayStrain: nil, recentShortfalls: [20000, 20000, 20000]).debt == 7200, "Debt capped")
check(SleepEngine.performance(asleep: 30000, need: 34200)! > 0.87 && SleepEngine.performance(asleep: 40000, need: 34200) == 1, "Performance capped at 100%")
check(SleepEngine.consistency(onsets: [-60, -60, -60], wakes: [420, 420, 420]) == 100, "Identical nights are fully consistent")
check(SleepEngine.consistency(onsets: [-60], wakes: [420]) == nil, "Consistency needs two nights")

let base = [50.0, 52, 51, 53, 49, 50, 52].map { RecoveryEngine.Night(restingHR: $0, rmssd: nil, sleepPerformance: nil) }
if case .ready(let result) = RecoveryEngine.score(tonight: .init(restingHR: 51, rmssd: nil, sleepPerformance: nil), baseline: base) {
    check(result.score == 58 && result.band == .yellow && !result.usedHRV, "Baseline night scores about 58")
} else { check(false, "Baseline should be ready") }
if case .ready(let worse) = RecoveryEngine.score(tonight: .init(restingHR: 60, rmssd: nil, sleepPerformance: nil), baseline: base) { check(worse.score < 34 && worse.band == .red, "Worse resting HR lowers recovery") } else { check(false, "ready") }
if case .ready(let better) = RecoveryEngine.score(tonight: .init(restingHR: 46, rmssd: nil, sleepPerformance: nil), baseline: base) { check(better.score > 67 && better.band == .green, "Better resting HR raises recovery") } else { check(false, "ready") }
check(RecoveryEngine.score(tonight: .init(restingHR: 51, rmssd: nil, sleepPerformance: nil), baseline: Array(base.prefix(2))) == .calibrating(nights: 2), "Fewer than 4 nights calibrates")
check(RecoveryEngine.score(tonight: .init(restingHR: 51, rmssd: nil, sleepPerformance: nil), baseline: Array(base.prefix(3))) == .calibrating(nights: 3), "Three nights still calibrate")
if case .ready(let early) = RecoveryEngine.score(tonight: .init(restingHR: 51, rmssd: nil, sleepPerformance: nil), baseline: Array(base.prefix(4))) { check(early.early, "Recovery after four nights is Early") } else { check(false, "Recovery appears after four nights") }

let rest = CalorieEngine.bmr(profile)! / 1440
let hours = CalorieEngine.hourly(makeSeries([(150, 0)]), profile: profile, elapsedMinutes: 150)!
check(abs(hours[0]! - rest * 60) < 1e-9 && abs(hours[2]! - rest * 30) < 1e-9 && hours[3] == nil, "Hourly calories resting only, future hours nil")
let active = CalorieEngine.hourly(makeSeries([(60, 150)]), profile: profile, elapsedMinutes: 60)!
check(abs(active[0]! - 868.0) < 5, "One hour at 150 bpm equals the Keytel gross of about 868 kcal for this profile")

// Storage v3: migrate a v2 file, round-trip detections, sleeps and ranges.
let v2 = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
defer { for suffix in ["", "-wal", "-shm"] { try? FileManager.default.removeItem(atPath: v2.path + suffix) } }
var raw: OpaquePointer?
check(sqlite3_open(v2.path, &raw) == SQLITE_OK, "Create v2 file")
check(sqlite3_exec(raw, "CREATE TABLE frames(device TEXT NOT NULL, payload BLOB NOT NULL, received REAL NOT NULL, UNIQUE(device,payload)); CREATE TABLE samples(id TEXT PRIMARY KEY, time REAL NOT NULL, bpm INTEGER NOT NULL); CREATE TABLE live_minutes(minute INTEGER PRIMARY KEY,bpm_avg REAL,bpm_min INTEGER,bpm_max INTEGER,count INTEGER,rr_rmssd REAL); INSERT INTO samples VALUES('x',1750000000,70); PRAGMA user_version=2;", nil, nil, nil) == SQLITE_OK, "Seed v2")
sqlite3_close(raw)
let migrated = try HistoryStore(url: v2)
check(try! migrated.recent().count == 1, "v2 samples survive migration")
try migrated.saveDetection(stored[0]); try migrated.saveDetection(stored[0])
check(try! migrated.detections(since: .distantPast) == stored, "Detection round trip, idempotent")
try migrated.saveSleep(sleep, wakeDay: 20_000)
check(try! migrated.sleeps(fromDay: 19_990, toDay: 20_010).first?.session == sleep, "Sleep round trip")
try migrated.insertSamples([Sample(id: "y", date: Date(timeIntervalSince1970: 1_750_000_100), bpm: 80)])
check(try! migrated.samples(from: Date(timeIntervalSince1970: 1_750_000_050), to: Date(timeIntervalSince1970: 1_750_000_200)).map(\.bpm) == [80], "Sample range query")
check(try! migrated.latestSampleDate() == Date(timeIntervalSince1970: 1_750_000_100), "Latest sample")
check(try! (try! JSONDecoder().decode(Workout.self, from: Data(#"{"id":"\#(UUID().uuidString)","type":"Running","start":0,"pausedSeconds":0,"readings":[]}"#.utf8))).source == nil, "Old workout JSON still decodes")

let now = Date(timeIntervalSince1970: 1_750_100_000)
check(SyncPolicy.shouldSync(.foreground, now: now, lastSuccess: now.addingTimeInterval(-30), lastAttempt: nil, isSyncing: false, lowPower: false) == false, "Fresh cache skips foreground sync")
check(SyncPolicy.shouldSync(.foreground, now: now, lastSuccess: now.addingTimeInterval(-1000), lastAttempt: nil, isSyncing: false, lowPower: false), "Stale cache syncs on foreground")
check(SyncPolicy.shouldSync(.foreground, now: now, lastSuccess: nil, lastAttempt: now.addingTimeInterval(-5), isSyncing: false, lowPower: false) == false, "Coalesced triggers")
check(SyncPolicy.shouldSync(.reconnect, now: now, lastSuccess: now.addingTimeInterval(-600), lastAttempt: nil, isSyncing: false, lowPower: false) == false, "Reconnect waits 30 minutes")
check(SyncPolicy.shouldSync(.background, now: now, lastSuccess: now.addingTimeInterval(-3600), lastAttempt: nil, isSyncing: false, lowPower: true) == false, "Low power defers background sync")
check(SyncPolicy.shouldSync(.background, now: now, lastSuccess: now.addingTimeInterval(-3600), lastAttempt: nil, isSyncing: false, lowPower: false), "Background sync after 30 minutes")
check(SyncPolicy.shouldSync(.manual, now: now, lastSuccess: now, lastAttempt: now, isSyncing: false, lowPower: true), "Manual always allowed")
check(SyncPolicy.shouldSync(.manual, now: now, lastSuccess: nil, lastAttempt: nil, isSyncing: true, lowPower: false) == false, "Never overlap transfers")
// Reject stale, unsolicited and truncated command responses, including sequence wrap.
for seq in UInt8.min...UInt8.max {
    check(HistoryProtocol.matchesResponse([0x24, seq &+ 17, 0x23, seq, 1], command: .hello, sequence: seq), "Matching response accepted")
    check(!HistoryProtocol.matchesResponse([0x24, seq, 0x23, seq &+ 1, 1], command: .hello, sequence: seq), "Stale response rejected")
    check(!HistoryProtocol.matchesResponse([0x24, seq, 0x22, seq, 1], command: .hello, sequence: seq), "Wrong opcode rejected")
}
check(!HistoryProtocol.matchesResponse([0x24, 1], command: .hello, sequence: 1), "Truncated response rejected")
check(!HistoryProtocol.matchesResponse([0x24, 1, 0x23, 1, 1], command: .hello, sequence: nil), "Duplicate consumed response rejected")

print("Detection, sleep, recovery, storage and sync-policy checks passed")

// Calibration gates, adaptation and sustained activity adversarial cases.
let calibrationNow = Date(timeIntervalSince1970: 1_760_000_000)
func calibrationDay(_ offset: Int, count: Int = 1440, rest: Double? = 60) -> CalibrationDay {
    let end = calibrationNow.addingTimeInterval(Double(-offset) * 86400)
    let start = end.addingTimeInterval(-86400)
    let first = Int64(start.timeIntervalSince1970 / 60)
    let series: [MinuteHR?] = (0..<count).map { MinuteHR(minute: first + Int64($0),average: 130,minimum: 130,maximum: 130,count: 1) }
    return CalibrationDay(start: start,end: end,series: series,rest: rest)
}
let sevenDays = (0..<7).map { calibrationDay($0) }
let learned = CalibrationEngine.update(BaselineSnapshot(),days: sevenDays,now: calibrationNow)
check(learned.load.established && learned.resting.established && !learned.hrv.established, "Independent calibration gates")
check(learned.restingHR == 60, "Resting median initialized")
check(CalibrationEngine.update(learned,days: sevenDays,now: calibrationNow) == learned, "Refresh cannot adapt twice")
check(!CalibrationEngine.update(BaselineSnapshot(),days: Array(sevenDays.prefix(3)),now: calibrationNow).resting.established, "Three nights cannot unlock")
check(CalibrationEngine.update(BaselineSnapshot(),days: Array(sevenDays.prefix(4)),now: calibrationNow).resting.established, "Four nights unlock")
var coverageDay = calibrationDay(0)
for i in 0..<360 { coverageDay.series[i * 4] = nil }
check(CalibrationEngine.qualifies(coverageDay,now: calibrationNow), "Exactly 75 percent qualifies")
coverageDay.series[1] = nil
check(!CalibrationEngine.qualifies(coverageDay,now: calibrationNow), "Below 75 percent fails")
var gapDay = calibrationDay(0)
for i in 0..<181 { gapDay.series[i] = nil }
check(!CalibrationEngine.qualifies(gapDay,now: calibrationNow), "Large gap rejects otherwise dense day")
var excludedDay = calibrationDay(0); excludedDay.excluded = true
check(!CalibrationEngine.qualifies(excludedDay,now: calibrationNow), "Illness day excluded")
var unfinished = calibrationDay(0); unfinished.end = calibrationNow.addingTimeInterval(1)
check(!CalibrationEngine.qualifies(unfinished,now: calibrationNow), "Current day cannot qualify")
check(learned.resting.stale(at: calibrationNow.addingTimeInterval(8 * 86400)), "Baseline becomes stale")
let zoneSettings = ZoneConfiguration(maximum: 200,resting: 60,maximumSource: "Manual")
check(zoneSettings.zone(115) == nil && zoneSettings.zone(116) == 1 && zoneSettings.zone(144) == 2 && zoneSettings.zone(186) == 5, "HR reserve boundaries")
check(zoneSettings.zone(.nan) == nil && zoneSettings.zone(.infinity) == nil, "Nonfinite zones rejected")
var highDays = (0..<7).map { calibrationDay($0,rest: 70) }
highDays[0].end = calibrationNow.addingTimeInterval(86400)
let adapted = CalibrationEngine.update(learned,days: highDays,now: calibrationNow.addingTimeInterval(86400))
check(abs((adapted.restingHR ?? 0) - (60 + 2.0 / 7)) < 1e-9, "Resting update capped at 2 bpm a week")
let activeSeries = Array(calibrationDay(0).series.prefix(20))
check(CalibrationEngine.activities(Array(activeSeries.prefix(9)),zones: zoneSettings,excluded: []).isEmpty, "Short elevated HR rejected")
let activities = CalibrationEngine.activities(activeSeries,zones: zoneSettings,excluded: [])
check(activities.count == 1 && activities[0].minutes.count == 20, "Sustained HR classified as unconfirmed")
var interrupted = activeSeries; interrupted[8] = nil; interrupted[9] = nil
check(CalibrationEngine.activities(interrupted,zones: zoneSettings,excluded: []).first?.minutes.count == 18, "A 2-minute gap does not split an effort, and missing minutes are not counted")
check(CalibrationEngine.activities(activeSeries,zones: zoneSettings,excluded: [DateInterval(start: calibrationDay(0).start.addingTimeInterval(-60),end: calibrationNow)]).isEmpty, "Sleep or dismissal excludes activity")
let weightDate = calibrationNow.addingTimeInterval(-3600)
let weights = [WeightEntry(date: weightDate,kg: 60),WeightEntry(date: calibrationNow.addingTimeInterval(1),kg: 90)]
check(CalibrationEngine.profile(profile,at: calibrationNow,weights: weights).weightKg == 60, "Future weight does not leak backwards")
check(CalibrationEngine.profile(profile,at: weightDate.addingTimeInterval(-1),weights: weights).weightKg == profile.weightKg, "Earlier profile preserved")
let energyFrom = Date(timeIntervalSince1970: Double(activeSeries[0]!.minute) * 60)
let energyTo = energyFrom.addingTimeInterval(20 * 60)
var walking = Workout(type: "Walking"); walking.start = energyFrom; walking.end = energyTo
let single = AdaptiveCalories.estimate(activeSeries,from: energyFrom,to: energyTo,profile: profile,zones: zoneSettings,weights: [],workouts: [walking],excluded: [])
let duplicate = AdaptiveCalories.estimate(activeSeries,from: energyFrom,to: energyTo,profile: profile,zones: zoneSettings,weights: [],workouts: [walking,walking],excluded: [])
check(single.active > 0 && single.active == duplicate.active && single.unconfirmed.isEmpty, "Workout overlap counted once")
walking.pauses = [DateInterval(start: energyFrom,end: energyTo)]
check(AdaptiveCalories.estimate(activeSeries,from: energyFrom,to: energyTo,profile: profile,zones: zoneSettings,weights: [],workouts: [walking],excluded: []).active == 0, "Paused minutes excluded")
var rrMinute = activeSeries[0]!; rrMinute.rmssd = 30; rrMinute.validRRCount = 25
try migrated.saveLiveMinute(rrMinute)
check(try! migrated.liveMinutes(from: energyFrom,to: energyTo).first?.validRRCount == 25, "RR continuity metadata persists")
let merged = HRTimeline.minuteSeries(history: [Sample(id: "merge",date: energyFrom,bpm: 80)],live: [rrMinute],workoutReadings: [],from: energyFrom,to: energyFrom.addingTimeInterval(60))
check(merged[0]?.average == 80 && merged[0]?.validRRCount == 25 && merged[0]?.rmssd == 30, "History preserves independent RR evidence")
try migrated.saveDocument(learned,key: "baseline")
check(try! migrated.document("baseline",as: BaselineSnapshot.self) == learned, "Baseline round trip")
try migrated.saveRevision(learned,key: "test"); try migrated.saveRevision(learned,key: "test")
check(try! migrated.metricRevisions().count == 1, "Unchanged results do not create duplicate revisions")
print("Calibration, sustained activity, adaptation, dated weights and v4 persistence checks passed")
// Calendar-length days use their actual duration, not a fixed 1,440 bins.
for hours in [23,25] {
    var day = calibrationDay(0,count: hours * 60)
    day.start = day.end.addingTimeInterval(Double(-hours) * 3600)
    check(CalibrationEngine.qualifies(day,now: calibrationNow), "DST day coverage uses actual day length")
}
var malformedDay = calibrationDay(0,count: 20)
check(!CalibrationEngine.qualifies(malformedDay,now: calibrationNow), "Short array cannot impersonate a full day")
let retained = CalibrationEngine.update(learned,days: [],now: calibrationNow.addingTimeInterval(40 * 86400))
check(retained.restingHR == learned.restingHR && !retained.resting.established && retained.resting.stale(at: calibrationNow.addingTimeInterval(40 * 86400)), "Missing data keeps the old resting HR but the baseline lapses")
var strength = Workout(type: "Strength"); strength.start = energyFrom; strength.end = energyTo
check(AdaptiveCalories.estimate(activeSeries,from: energyFrom,to: energyTo,profile: profile,zones: zoneSettings,weights: [],workouts: [strength],excluded: []).active == 0, "Unsupported workout does not become unconfirmed aerobic energy")
try migrated.saveRevision(adapted,key: "test")
check(try! migrated.metricRevisions().count == 2, "Changed results append a revision")
print("DST, sparse-day, stale baseline and result revision checks passed")

check(HistoryProtocol.matchesResponse([0x24,0x46,0x22,0x02,0x01,0x01],command: .range,sequence: 0x02), "User-captured WHOOP 4 range reply uses origin sequence, not response sequence")
check(!HistoryProtocol.matchesResponse([0x24,0x46,0x22,0x02,0x01,0x01],command: .range,sequence: 0x46), "Response packet counter cannot masquerade as request origin")

check(HistoryProtocol.clockResponse([0x24,0,0x0b,0,2,0x78,0x56,0x34,0x12]) == nil, "Pending clock reply cannot trigger clock repair")

// MARK: Phase 2: full record decode, schema v5, minute aggregation
func makeRecord(time: UInt32, bpm: UInt8, rr: [UInt16] = [], gravity: [Float] = [0, 0, 1], red: UInt16 = 700, ir: UInt16 = 600, skin: UInt16 = 900, counter: UInt32 = 1) -> [UInt8] {
    var r = Array(repeating: UInt8(0), count: 96)
    r[0] = 0x2f; r[1] = 24; r[17] = bpm; r[18] = UInt8(rr.count)
    for i in 0..<4 { r[3 + i] = UInt8(truncatingIfNeeded: counter >> (8 * i)); r[7 + i] = UInt8(truncatingIfNeeded: time >> (8 * i)) }
    for (i, v) in rr.enumerated() { r[19 + 2 * i] = UInt8(v & 255); r[20 + 2 * i] = UInt8(v >> 8) }
    for (i, g) in gravity.enumerated() { let b = g.bitPattern; for j in 0..<4 { r[36 + 4 * i + j] = UInt8(truncatingIfNeeded: b >> (8 * UInt32(j))) } }
    r[64] = UInt8(red & 255); r[65] = UInt8(red >> 8); r[66] = UInt8(ir & 255); r[67] = UInt8(ir >> 8); r[68] = UInt8(skin & 255); r[69] = UInt8(skin >> 8)
    return r
}
let full = HistoryProtocol.record(makeRecord(time: 1_750_000_000, bpm: 64, rr: [800, 820, 5000]))
check(full?.bpm == 64 && full?.rr == [800, 820], "Record decodes heart rate and drops out-of-range RR")
check(full?.gravity == [0, 0, 1] && full?.red == 700 && full?.ir == 600 && full?.skinRaw == 900, "Record decodes gravity and optical words")
check(HistoryProtocol.record(makeRecord(time: 1_750_000_000, bpm: 64, gravity: [5, 5, 5]))?.gravity == nil, "Implausible gravity becomes nil")
check(HistoryProtocol.record(Array(makeRecord(time: 1_750_000_000, bpm: 64).prefix(80))) == nil, "Truncated record rejected")
var badVersion = makeRecord(time: 1_750_000_000, bpm: 64); badVersion[1] = 23
check(HistoryProtocol.record(badVersion) == nil, "Wrong record version rejected")
var badCount = makeRecord(time: 1_750_000_000, bpm: 64); badCount[18] = 9
check(HistoryProtocol.record(badCount) == nil, "RR count above 4 rejected")

var minuteRecords: [HistoryProtocol.Record] = []
for s in 0..<60 {
    minuteRecords.append(HistoryProtocol.record(makeRecord(time: 1_750_000_020 + UInt32(s), bpm: 60, rr: s % 3 == 0 ? [1000, 1040] : [], gravity: [0, 0, s % 2 == 0 ? 1.0 : 1.01]))!)
}
let aggregated = HRTimeline.aggregate(minuteRecords)
check(aggregated.count == 2 || aggregated.count == 1, "Aggregation groups by minute")
check(aggregated.reduce(0) { $0 + $1.rrPairs } == 20 && abs(aggregated.reduce(0.0) { $0 + $1.rrSumSquares } - 20 * 1600) < 1e-6, "RR pairs counted inside records only")
check((aggregated.compactMap(\.motion).first ?? 0) > 9 && (aggregated.compactMap(\.motion).first ?? 0) < 11, "Motion is mean gravity change in milli-g")
check(abs(HRTimeline.pooledRMSSD(aggregated.map { Optional(MinuteHR(minute: $0.minute, average: $0.bpmAverage, minimum: $0.bpmMinimum, maximum: $0.bpmMaximum, count: $0.count, rmssd: nil, validRRCount: nil, motion: $0.motion, rrPairs: $0.rrPairs, rrSumSquares: $0.rrSumSquares)) })! - 40) < 1e-6, "Pooled RMSSD")

let v5url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
defer { for suffix in ["", "-wal", "-shm"] { try? FileManager.default.removeItem(atPath: v5url.path + suffix) } }
do {
    var v4: OpaquePointer?
    check(sqlite3_open(v5url.path, &v4) == SQLITE_OK, "Open temp v4 database")
    let rawFrames = (0..<5).map { makeRecord(time: 1_750_000_000 + UInt32($0), bpm: 70, rr: [900, 910], counter: UInt32($0)) }
    var sql = "CREATE TABLE frames(device TEXT NOT NULL, payload BLOB NOT NULL, received REAL NOT NULL, UNIQUE(device,payload)); CREATE TABLE samples(id TEXT PRIMARY KEY,time REAL NOT NULL,bpm INTEGER NOT NULL); CREATE TABLE live_minutes(minute INTEGER PRIMARY KEY,bpm_avg REAL,bpm_min INTEGER,bpm_max INTEGER,count INTEGER,rr_rmssd REAL); CREATE TABLE detected_activities(id TEXT PRIMARY KEY,start REAL NOT NULL,end REAL NOT NULL,status TEXT NOT NULL,payload TEXT NOT NULL); CREATE TABLE sleeps(wake_day INTEGER PRIMARY KEY,payload TEXT NOT NULL); CREATE TABLE health_documents(key TEXT PRIMARY KEY,payload BLOB NOT NULL); CREATE TABLE metric_revisions(id INTEGER PRIMARY KEY AUTOINCREMENT,key TEXT NOT NULL,payload BLOB NOT NULL,created REAL NOT NULL); ALTER TABLE live_minutes ADD COLUMN rr_count INTEGER; PRAGMA user_version=4;"
    for f in rawFrames { sql += "INSERT INTO frames VALUES('dev',X'\(f.map { String(format: "%02x", $0) }.joined())',1);" }
    check(sqlite3_exec(v4, sql, nil, nil, nil) == SQLITE_OK, "Build v4 fixture")
    sqlite3_close(v4)
}
let upgraded = try HistoryStore(url: v5url)
let rebuilt = try upgraded.historyMinutes(from: Date(timeIntervalSince1970: 1_749_999_000), to: Date(timeIntervalSince1970: 1_750_001_000))
check(rebuilt.values.reduce(0) { $0 + $1.count } == 5 && rebuilt.values.reduce(0) { $0 + $1.rrPairs } == 5, "v4 to v5 migration rebuilds records and minutes")
try upgraded.persist([makeRecord(time: 1_750_000_100, bpm: 66, rr: [800, 820])], device: "dev", cursor: [1, 2, 3, 4, 5, 6, 7, 8])
print("Phase 2 record decode, migration and aggregation checks passed")

// MARK: Phases 4 and 5: sleep with motion, naps, calibration phases
func syntheticDay(hours: Int, bpmAt: (Int) -> Double, motionAt: (Int) -> Double? = { _ in 5 }, startMinute: Int64 = 29_000_000) -> [MinuteHR?] {
    (0..<(hours * 60)).map { i in
        let v = bpmAt(i)
        return MinuteHR(minute: startMinute + Int64(i), average: v + Double(i % 3), minimum: Int(v), maximum: Int(v) + 2, count: 60, motion: motionAt(i), skinRaw: 940)
    }
}
// 14 h window: 4 h awake at 78 bpm, 8 h asleep at 54, 2 h awake.
let nightSeries = syntheticDay(hours: 14, bpmAt: { $0 < 240 ? 78 : $0 < 720 ? 54 : 78 })
let nightFound = SleepEngine.detect(nightSeries, firstMinute: 29_000_000, daytimeBaseline: 78)
check(nightFound != nil, "Clean night is found")
if let night = nightFound {
    let onsetError = abs(night.start.timeIntervalSince1970 / 60 - Double(29_000_000 + 240))
    let wakeError = abs(night.end.timeIntervalSince1970 / 60 - Double(29_000_000 + 720))
    check(onsetError <= 15 && wakeError <= 15, "Onset and wake within 15 minutes of the constructed night")
    check(night.disturbances == 0 && night.skinRaw == 940, "Quiet night has no disturbances and a skin value")
}
// Ten continuous minutes of movement with an unchanged heart rate is an awakening.
let restlessSeries = syntheticDay(hours: 14, bpmAt: { $0 < 240 ? 78 : $0 < 720 ? 54 : 78 }, motionAt: { $0 >= 400 && $0 < 410 ? 200 : 5 })
let restless = SleepEngine.detect(restlessSeries, firstMinute: 29_000_000, daytimeBaseline: 78)
check((restless?.disturbances ?? 0) >= 1 && (restless?.awake ?? 0) >= 600, "Sustained movement counts as an awakening without a heart-rate rise")
// Off-wrist hour inside the night is no-data, not wake.
var gappedSeries = nightSeries
for i in 400..<460 { gappedSeries[i] = nil }
let gapped = SleepEngine.detect(gappedSeries, firstMinute: 29_000_000, daytimeBaseline: 78)
check((gapped?.noData ?? 0) >= 3000 && (gapped?.awake ?? 1) == 0, "Missing hour is no-data and is not counted as wake")
// Still TV-watching with a normal heart rate is not sleep.
let tv = syntheticDay(hours: 14, bpmAt: { _ in 74 })
check(SleepEngine.detect(tv, firstMinute: 29_000_000, daytimeBaseline: 78) == nil, "Sedentary evening at a normal heart rate is not sleep")

// Naps: 45 min found; 20 min ignored; 90 min found and shortens need.
func napDay(napMinutes: Int) -> [MinuteHR?] { syntheticDay(hours: 8, bpmAt: { $0 >= 120 && $0 < 120 + napMinutes ? 56 : 80 }) }
let napShort = SleepEngine.naps(napDay(napMinutes: 45), firstMinute: 29_000_000, daytimeBaseline: 80)
check(napShort.count == 1 && napShort[0].isNap == true && napShort[0].asleep < Double(HealthConstants.napDirectMinutes) * 60, "A 45-minute nap is found and needs review")
check(SleepEngine.naps(napDay(napMinutes: 20), firstMinute: 29_000_000, daytimeBaseline: 80).isEmpty, "A 20-minute doze is ignored")
let napLong = SleepEngine.naps(napDay(napMinutes: 90), firstMinute: 29_000_000, daytimeBaseline: 80)
check(napLong.count == 1 && napLong[0].asleep >= Double(HealthConstants.napDirectMinutes) * 60, "A 90-minute nap is saved directly")
let needNoNap = SleepEngine.need(baselineHours: 8, previousDayStrain: nil, recentShortfalls: [])
let needNap = SleepEngine.need(baselineHours: 8, previousDayStrain: nil, recentShortfalls: [], napSeconds: 90 * 60)
check(needNoNap.total - needNap.total == 90 * 60, "A 90-minute nap lowers that night's need by 90 minutes")
check(SleepEngine.need(baselineHours: 8, previousDayStrain: nil, recentShortfalls: [], napSeconds: 4 * 3600).nap == HealthConstants.napNeedCap, "Nap credit is capped")
check(SleepEngine.skinState(tonight: 990, history: Array(repeating: 940, count: 6)) == nil, "Skin state needs seven nights")
check(SleepEngine.skinState(tonight: 990, history: (0..<10).map { 940 + Double($0 % 2) }) == .above && SleepEngine.skinState(tonight: 941, history: (0..<10).map { 940 + Double($0 % 2) }) == .typical, "Skin state is relative to the user's own nights")

// Calibration phases and valid nights.
func nightSession(asleepHours: Double, coverage: Double = 0.95, nap: Bool = false) -> SleepSession {
    var s = SleepSession(start: Date(timeIntervalSince1970: 1_750_000_000), end: Date(timeIntervalSince1970: 1_750_028_800), inBed: asleepHours * 3600, asleep: asleepHours * 3600, awake: 0, stages: nil, sleepingHR: 55, lowestHR: 50, rmssd: nil, coverage: coverage)
    if nap { s.isNap = true }
    return s
}
check(CalibrationNights.verdict(nightSession(asleepHours: 7), excluded: false) == .counted, "A normal night counts")
check(CalibrationNights.verdict(nightSession(asleepHours: 3), excluded: false) == .missed(.tooShort), "Under 4 h does not count")
check(CalibrationNights.verdict(nightSession(asleepHours: 7, coverage: 0.7), excluded: false) == .missed(.gaps), "Under 80% measured does not count")
check(CalibrationNights.verdict(nightSession(asleepHours: 7), excluded: true) == .missed(.excluded), "Excluded day does not count")
check(CalibrationNights.verdict(nightSession(asleepHours: 1.5, nap: true), excluded: false) == .missed(.noSleep), "A nap is never a calibration night")
func nights(_ days: [Int]) -> [Int: SleepSession] { Dictionary(uniqueKeysWithValues: days.map { ($0, nightSession(asleepHours: 7)) }) }
check(CalibrationPhase.make(validNights: 0, setupComplete: false) == .setup, "Setup phase before setup is done")
check(CalibrationPhase.make(validNights: 3, setupComplete: true) == .calibrating(validNights: 3) && !CalibrationPhase.make(validNights: 3, setupComplete: true).recoveryAvailable, "No Recovery after 3 valid nights")
check(CalibrationPhase.make(validNights: 4, setupComplete: true) == .early(validNights: 4) && CalibrationPhase.make(validNights: 4, setupComplete: true).recoveryAvailable, "Recovery (Early) after 4 valid nights")
check(CalibrationPhase.make(validNights: 14, setupComplete: true) == .calibrated, "Calibrated at 14 nights")
check(CalibrationNights.validCount(sessions: nights([100, 101, 103]), excludedDays: [], today: 104) == 3, "A missed night pauses the count, it does not reset it")
check(CalibrationNights.validCount(sessions: nights([100, 101, 103]), excludedDays: [], today: 118) == 0, "The baseline lapses after 14 empty days")
check(CalibrationNights.validCount(sessions: nights([100, 101, 103, 119]), excludedDays: [], today: 119) == 4, "Nights count again when wear resumes")
check(CalibrationNights.log(sessions: nights([100]), excludedDays: [], today: 104).count == 14, "Night strip covers 14 days")
check(SetupState().remaining.count == 3 && SetupState(profileComplete: true, bandPaired: true, wornLastNight: true).isComplete, "Setup checklist")
// Zone boundary drift: resting HR falls 10 bpm, the baseline follows at no more than 2 bpm a week.
var drift = BaselineSnapshot(); drift.restingHR = 60
var driftDay = calibrationNow
for week in 0..<7 {
    let nightDays = (0..<7).map { calibrationDay($0, rest: 50) }
    let before = drift.restingHR ?? 0
    for offset in 0..<7 { driftDay = driftDay.addingTimeInterval(86400); var shifted = nightDays; for i in shifted.indices { shifted[i].end = driftDay.addingTimeInterval(Double(-i) * 86400); shifted[i].start = shifted[i].end.addingTimeInterval(-86400) }; drift = CalibrationEngine.update(drift, days: shifted, now: driftDay); _ = offset }
    check((before - (drift.restingHR ?? 0)) <= 2.0 + 1e-9, "Zone resting HR moves at most 2 bpm in week \(week + 1)")
}
check((drift.restingHR ?? 0) < 60 && (drift.restingHR ?? 0) >= 50, "Resting HR follows the drop gradually")
check(StrainEngine.score((0..<5).map { _ in MinuteHR(minute: 1, average: 150, minimum: 150, maximum: 150, count: 60) }, profile: profile) != nil, "Strain exists on day one with only a profile")
print("Phase 4 and 5 sleep, nap and calibration checks passed")
// A heart-rate dip with no motion data is not a nap; a still one is.
let napNoMotion = syntheticDay(hours: 8, bpmAt: { $0 >= 120 && $0 < 210 ? 56 : 80 }, motionAt: { _ in nil })
check(SleepEngine.naps(napNoMotion, firstMinute: 29_000_000, daytimeBaseline: 80).isEmpty, "Without motion data a heart-rate dip is not called a nap")
let napFidget = syntheticDay(hours: 8, bpmAt: { $0 >= 120 && $0 < 210 ? 56 : 80 }, motionAt: { $0 >= 120 && $0 < 210 ? ($0 % 2 == 0 ? 300 : 5) : 5 })
check(SleepEngine.naps(napFidget, firstMinute: 29_000_000, daytimeBaseline: 80).isEmpty, "A restless low-heart-rate stretch is not a nap")
print("Nap stillness checks passed")

// Band extras: battery reply and wrist/charging events
check(HistoryProtocol.batteryResponse([0x24,0,0x1a,0,1,0xdc,0x02]) == 73.2, "Battery reply decodes tenths of a percent")
check(HistoryProtocol.batteryResponse([0x24,0,0x1a,0,2,0xdc,0x02]) == nil, "Pending battery reply is ignored")
check(HistoryProtocol.batteryResponse([0x24,0,0x1a,0,1,0xff,0xff]) == nil, "Out-of-range battery is rejected")
let wristFrame: [UInt8] = [0x30,0x0b,0x09,0x00,0x13,0x85,0xf2,0x6a,0x28,0x2c,0x00,0x00]
check(HistoryProtocol.event(wristFrame)?.event == .wristOn && HistoryProtocol.event(wristFrame)?.date.timeIntervalSince1970 == Double(0x6af28513), "Wrist-on event")
check(HistoryProtocol.event([0x30,0x10,0x0a,0x00,0,0,0,0,0,0,0,0])?.event == .wristOff, "Wrist-off event")
check(HistoryProtocol.event([0x30,0x01,0x1d,0x00,0,0,0,0,0,0,0,0]) == nil, "Other events are ignored")
print("Band extras checks passed")

// Units
check(abs(UnitSystem.imperial.weight(fromKg: 70) - 154.32) < 0.01 && abs(UnitSystem.imperial.kilograms(fromDisplay: 154.32) - 70) < 0.01, "kg and lb convert both ways")
check(UnitSystem.feetInches(fromCm: 180).feet == 5 && UnitSystem.feetInches(fromCm: 180).inches == 11, "180 cm is 5 ft 11 in")
check(abs(UnitSystem.centimetres(feet: 5, inches: 11) - 180.34) < 0.01, "5 ft 11 in in centimetres")
check(UnitSystem.metric.weightText(70) == "70 kg" && UnitSystem.imperial.heightText(180) == "5 ft 11 in", "Unit text")
print("Unit checks passed")

// Active calories by source
var sourceEnergy = AdaptiveEnergy()
let minuteBase = Int64(29_000_000)
for m in 0..<30 { sourceEnergy.activeByMinute[minuteBase + Int64(m)] = 5 }          // 150 kcal in a manual workout
for m in 100..<110 { sourceEnergy.activeByMinute[minuteBase + Int64(m)] = 4 }       // 40 kcal outside any workout
sourceEnergy.active = 190
var manual = Workout(type: "Running"); manual.start = Date(timeIntervalSince1970: Double(minuteBase) * 60); manual.end = Date(timeIntervalSince1970: Double(minuteBase + 30) * 60)
sourceEnergy.unconfirmed = [ActivityEstimate(start: Date(timeIntervalSince1970: Double(minuteBase + 100) * 60), end: Date(timeIntervalSince1970: Double(minuteBase + 110) * 60), minutes: (100..<110).map { minuteBase + Int64($0) })]
let split = AdaptiveCalories.sources(sourceEnergy, workouts: [manual], now: Date())
check(split.count == 2 && split[0].kind == .manual && abs(split[0].kcal - 150) < 0.001, "Manual workout owns its active calories")
check(split[1].kind == .autoDetected && abs(split[1].kcal - 40) < 0.001, "Unconfirmed activity is auto-detected")
check(abs(split.reduce(0) { $0 + $1.kcal } - sourceEnergy.active) < 0.001, "Sources add up to the active total")
sourceEnergy.active = 200
check(AdaptiveCalories.sources(sourceEnergy, workouts: [manual], now: Date()).last?.kind == .other, "Leftover burn is other movement")
print("Calorie source checks passed")

// Priority-1 fixes
// The false nap from 10 Nov: heart rate barely lower than before, steady movement of 100–450 mg.
let restlessNap = syntheticDay(hours: 8, bpmAt: { $0 >= 120 && $0 < 160 ? 70 : 82 }, motionAt: { $0 >= 120 && $0 < 160 ? [120, 260, 180, 440, 90][$0 % 5] : 60 })
check(SleepEngine.naps(restlessNap, firstMinute: 29_000_000, daytimeBaseline: 82).isEmpty, "Uniformly restless low-HR stretch is not a nap")
check(!SleepEngine.napIsStill([5, 5, 150, 160, 170, 5, 5, 5, 5, 5]), "Three minutes of movement in a row rule out a nap")
check(SleepEngine.napIsStill([5, 5, 150, 5, 5, 5, 5, 5, 5, 5]), "One restless minute is allowed")
check(SleepEngine.naps(napDay(napMinutes: 45), firstMinute: 29_000_000, daytimeBaseline: 80).count == 1, "A still 45-minute nap is still found")
// Resting HR ignores a half-rate glitch and moving minutes.
var glitchNight: [MinuteHR] = (0..<120).map { MinuteHR(minute: Int64($0), average: 58 + Double($0 % 3), minimum: 58, maximum: 61, count: 60, motion: 5) }
for i in 50..<60 { glitchNight[i].average = 30 }
check((CalibrationEngine.restingHR(glitchNight) ?? 0) >= 58, "Half-rate glitch does not set resting heart rate")
for i in 80..<90 { glitchNight[i].average = 50; glitchNight[i].motion = 300 }
check((CalibrationEngine.restingHR(glitchNight) ?? 0) >= 58, "Moving minutes do not set resting heart rate")
// HRV comes from history beat pairs only, ignoring live-stream values.
var hrvNight = syntheticDay(hours: 14, bpmAt: { $0 < 240 ? 78 : $0 < 720 ? 54 : 78 })
for i in hrvNight.indices { hrvNight[i]?.rrPairs = 10; hrvNight[i]?.rrSumSquares = 10 * 1600; hrvNight[i]?.rmssd = i == 300 ? 99 : nil }
let hrvFound = SleepEngine.detect(hrvNight, firstMinute: 29_000_000, daytimeBaseline: 78)
check(abs((hrvFound?.rmssd ?? 0) - 40) < 0.001, "Night HRV uses one source")
print("Priority-1 algorithm fix checks passed")

// Sleep onset needs stillness; quiet-wake baseline
let movingLow = syntheticDay(hours: 14, bpmAt: { $0 < 240 ? 78 : $0 < 720 ? 54 : 78 }, motionAt: { $0 >= 240 && $0 < 720 ? 150 : 5 })
check(SleepEngine.detect(movingLow, firstMinute: 29_000_000, daytimeBaseline: 78) == nil, "Low heart rate while moving is not sleep")
let movingWake = syntheticDay(hours: 14, bpmAt: { $0 < 240 ? 78 : $0 < 720 ? 54 : 78 }, motionAt: { $0 >= 600 && $0 < 720 ? 150 : 5 })
if let early = SleepEngine.detect(movingWake, firstMinute: 29_000_000, daytimeBaseline: 78) {
    check(abs(early.end.timeIntervalSince1970 / 60 - Double(29_000_000 + 600)) <= 15, "Sustained movement ends the night")
} else { check(false, "Night before sustained movement is found") }
let busyDay = syntheticDay(hours: 13, bpmAt: { $0 < 360 ? 100 : 74 }, motionAt: { $0 < 360 ? 300 : 5 })
check(abs((SleepEngine.quietBaseline(busyDay) ?? 0) - 75) < 1.5, "Quiet baseline uses still minutes only")
check(SleepEngine.quietBaseline(Array(busyDay.prefix(30))) == nil, "Too little data gives no baseline")
print("Sleep stillness and quiet baseline checks passed")

// Oxygen-uptake energy model
check(abs(EnergyModel.vo2max(maximumHR: 190, restingHR: 60) - 48.45) < 0.01, "Uth VO2max estimate")
check(EnergyModel.vo2max(maximumHR: 200, restingHR: 35) == 70, "VO2max is capped")
let atRest = EnergyModel.grossKcal(hr: 90, weightKg: 70, maximumHR: 190, restingHR: 90, vo2max: 45)
check(abs(atRest - 3.5 * 70 / 1000 * 4.69) < 0.001, "Awake resting heart rate gives resting oxygen uptake")
let hard = EnergyModel.grossKcal(hr: 190, weightKg: 70, maximumHR: 190, restingHR: 90, vo2max: 45)
check(abs(hard - 45 * 70 / 1000 * 5.05) < 0.001, "Maximum heart rate gives VO2max at 5.05 kcal per litre")
check(EnergyModel.grossKcal(hr: 140, weightKg: 70, maximumHR: 190, restingHR: 90, vo2max: 45) < hard, "Energy rises with heart rate")
// Everyday movement: raised heart rate counts only while the wrist is moving.
let moveZones = ZoneConfiguration(maximum: 190, resting: 55, maximumSource: "test")
let moveStart = Date(timeIntervalSince1970: 29_000_000 * 60)
func everyday(_ motion: Double) -> AdaptiveEnergy {
    let series: [MinuteHR?] = (0..<30).map { MinuteHR(minute: 29_000_000 + Int64($0), average: 112, minimum: 110, maximum: 114, count: 60, motion: motion) }
    return AdaptiveCalories.estimate(series, from: moveStart, to: moveStart.addingTimeInterval(1800), profile: profile, zones: moveZones, weights: [], workouts: [], excluded: [], awakeHR: 90)
}
check(everyday(300).active > 0 && everyday(300).unconfirmed.isEmpty, "Walking at a modest heart rate counts as everyday movement")
check(everyday(20).active == 0, "Raised heart rate while sitting still stays at rest")
print("Energy model checks passed")
