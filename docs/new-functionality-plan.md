# Implementation plan: new health functionality

For: Codex (or any coding agent). Read this whole file before starting. Work phase by phase, in order; each phase ends in a buildable app and passing checks.

## 1. Context

Personal Tracker is a native iOS 17 SwiftUI app (`project.yml`, XcodeGen) that talks to a WHOOP 4 band over Bluetooth with no account or server. Today it can:

- stream live heart rate (`BandManager.recordLive`, `Tracker/TrackerApp.swift:59-70`), keeping only the last 120 readings in memory (`liveSamples`);
- run manual workouts (`startWorkout` / `pauseWorkout` / `finishWorkout`, `TrackerApp.swift:75-89`), saved to `Application Support/workouts.json`;
- sync historical heart rate into SQLite (`Tracker/HistoryStore.swift`, table `samples(id, time, bpm)`), one decoded HR value per 96-byte `0x2F` record.

It cannot compute calories, sleep, strain, recovery, auto-detect workouts, send notifications, or show a Live Activity. This plan adds those. A separate design canvas ("Personal Tracker Redesign") shows the target screens; **this plan covers functionality and the data the UI needs, not the visual redesign.** Each phase only adds minimal UI hooks so results can be seen.

## 2. Ground rules

1. **No invented data.** Every number shown must come from measured samples. When inputs are missing or too sparse, return `nil` and show a "Not enough data" / "Calibrating" state. Never fill with sample values.
2. **Label estimates.** Calories, sleep stages, strain and recovery are estimates from heart rate only. Model types carry a `confidence` or `isEstimate` flag; UI text says "Estimated".
3. **Pure engines.** All calculations live in pure Swift types with no SwiftUI, CoreBluetooth, ActivityKit or UserDefaults imports, so they compile into the existing command-line checks (`Tests/main.swift`). Inputs in, value out.
4. **Do not touch the BLE protocol** (`FrameDecoder.swift`, `HistoryProtocol.swift`, the sync state machine in `BandManager.receive`) except where a step says so.
5. **Durability.** Keep the existing rule: data is written to SQLite before it is acknowledged or shown as saved. Schema changes go through a versioned migration.
6. **Backward compatibility.** Existing `workouts.json` files and `history.sqlite` databases must still load. New `Codable` fields use `decodeIfPresent` with defaults.
7. **Constants in one place.** Every tunable threshold lives in `Tracker/Health/HealthConstants.swift` with a comment explaining it.
8. Keep `BandManager` focused on Bluetooth. New logic goes in a new `HealthEngine` (see §4).

## 3. Known limits to respect

- **Only heart rate is decoded.** No accelerometer, skin temperature or SpO₂. The `0x2B` raw frames (1928 bytes) may contain motion data, but that is unverified; do not depend on it. Sleep and detection are HR-only.
- **History sample cadence is unknown.** Phase 1 measures it. All algorithms work on a per-minute resampled series where minutes without data are explicitly missing.
- **RR intervals** are parsed from the standard HR characteristic (`HeartRateReading.rrMilliseconds`) but discarded, and are only available while live streaming. HRV is therefore optional: use it when present, never require it.
- **Background execution.** The app has `bluetooth-central` background mode but only streams live HR while Today is visible or a workout runs (`updateStreaming`, `TrackerApp.swift:35-58`). Auto-detection therefore runs (a) on the live stream while streaming and (b) over history after each sync. Do not add always-on streaming; it drains the band.

## 4. Architecture

New folder `Tracker/Health/` (added automatically, since `project.yml` compiles all of `Tracker/`):

| File | Kind | Responsibility |
|---|---|---|
| `HealthConstants.swift` | pure | all thresholds and coefficients |
| `UserProfile.swift` | pure + Codable | age, weight kg, height cm, sex, optional max/resting HR overrides |
| `HRTimeline.swift` | pure | merge samples into a per-minute series with gaps |
| `Zones.swift` | pure | max HR, zone boundaries, zone of a BPM, time in zone |
| `StrainEngine.swift` | pure | TRIMP and 0–21 strain |
| `CalorieEngine.swift` | pure | BMR, per-minute active/resting kcal |
| `SleepEngine.swift` | pure | sleep window detection, stage estimate, need, performance |
| `RecoveryEngine.swift` | pure | baseline and 0–100 recovery score |
| `ActivityDetector.swift` | pure | workout detection state machine and type guess |
| `HealthModels.swift` | pure + Codable | `DailySummary`, `SleepSession`, `DetectedActivity`, `WorkoutMetrics` |
| `HealthStore.swift` | SQLite | new tables and queries (or extend `HistoryStore`, see Phase 1) |
| `HealthEngine.swift` | `@MainActor ObservableObject` | owns the store, recomputes, publishes results to UI |
| `NotificationService.swift` | UserNotifications | permission, categories, posting |
| `WorkoutActivityController.swift` | ActivityKit | start/update/end the Live Activity |

Shared with the widget extension: `Tracker/Shared/WorkoutActivityAttributes.swift` and `Tracker/Shared/WorkoutIntents.swift` (Phase 8).

Data flow:

```
BandManager (BLE) ──live readings──▶ HealthEngine.ingestLive(_:)
                 ──sync complete───▶ HealthEngine.historyDidChange()
                 ──workout events──▶ HealthEngine.workoutDidStart/Update/Finish
HealthEngine ─▶ HealthStore (SQLite) ─▶ engines ─▶ @Published dailySummary, lastSleep,
                                                    pendingDetections, activeWorkoutMetrics
           ─▶ NotificationService, WorkoutActivityController
```

`TrackerApp` creates `HealthEngine` alongside `BandManager` and injects both as environment objects. `BandManager` gets a weak/closure hook to forward events (no engine logic inside it).

## 5. Phases

Each phase lists tasks, files, acceptance criteria and checks. Add checks to `Tests/main.swift` and add the new pure files to the `swiftc` command in the README.

### Phase 0 — Profile and constants

Tasks
- `UserProfile`: `ageYears`, `weightKg`, `heightCm`, `sex` (`.male`, `.female`), `maxHROverride: Int?`, `restingHROverride: Int?`. Persist as JSON in `UserDefaults` key `userProfile`.
- `HealthConstants` skeleton (filled in by later phases).
- Minimal UI: a "Profile" form in the Device tab. Until a profile exists, calorie and strain features show "Add your profile".

Acceptance: profile survives relaunch; missing profile disables dependent metrics rather than defaulting silently.

### Phase 1 — Heart rate storage and timeline

Tasks
1. Schema migration in `HistoryStore` from `user_version=1` to `2`:
   - `CREATE INDEX IF NOT EXISTS samples_time ON samples(time)`.
   - New table `live_minutes(minute INTEGER PRIMARY KEY, bpm_avg REAL, bpm_min INTEGER, bpm_max INTEGER, count INTEGER, rr_rmssd REAL)` — `minute` is Unix seconds / 60.
   - Run the migration inside a transaction; check `PRAGMA user_version` first.
2. Persist live HR: in `HealthEngine.ingestLive`, accumulate readings per minute and flush each completed minute to `live_minutes` (also on app background and workout finish). Compute RMSSD from that minute's RR intervals when ≥ 20 intervals exist, else `NULL`.
3. Query API: `samples(from: Date, to: Date) -> [Sample]` and `liveMinutes(from:to:)`.
4. `HRTimeline.minuteSeries(history:live:workoutReadings:from:to:) -> [MinuteHR?]`: one slot per minute, averaging all sources in that minute, `nil` where there is no data. Sources overlap (a workout is also live), so average rather than add.
5. Cadence check: function `medianGapSeconds(_ samples:)`; show the value once in Device → Advanced so the real history resolution is known.

Checks: migration from a v1 file keeps existing samples; minute series puts `nil` in gaps; overlapping sources do not double count; flushing the same minute twice is idempotent (`INSERT OR REPLACE`).

### Phase 2 — Zones and strain

Tasks
- Max HR: `maxHROverride ?? round(208 − 0.7 × age)` (Tanaka).
- Zones as % of max HR: Z1 50–60, Z2 60–70, Z3 70–80, Z4 80–90, Z5 90–100. Below 50% is "no zone".
- `timeInZones(series) -> [Zone: TimeInterval]`.
- TRIMP (Edwards): Σ minutes in zone × zone number (1–5).
- Strain: `21 × (1 − exp(−TRIMP / k))` with `k = 200` in `HealthConstants` (gives ≈ 7–8 for a 24-minute run mostly in Z3–Z4; tune later). Clamp 0…21, one decimal.
- Day strain uses the day's minute series from local midnight; workout strain uses the workout's window.
- Extend `Workout` with optional cached `metrics: WorkoutMetrics?` (`avgHR`, `maxHR`, `zoneSeconds`, `strain`, `calories`), computed on finish.

Checks: zone boundaries for age 30 (max 187); a synthetic 30-minute series at 75% max gives TRIMP 90 and strain ≈ 7.9; empty series gives strain 0 and zero time in zones.

### Phase 3 — Calories

Tasks
- BMR (Mifflin–St Jeor): male `10W + 6.25H − 5A + 5`, female `10W + 6.25H − 5A − 161` kcal/day. Resting kcal per minute = BMR / 1440.
- Active energy per minute with HR in Z1 or above (Keytel et al., 2005):
  - male `(−55.0969 + 0.6309·HR + 0.1988·W + 0.2017·A) / 4.184`
  - female `(−20.4022 + 0.4472·HR − 0.1263·W + 0.074·A) / 4.184`
  - active kcal = `max(0, keytel − restingPerMinute)`.
- Minutes below Z1 or with no data count as resting only.
- Output `CalorieBreakdown { resting, active, total, hourly: [Double] (24), byWorkout: [UUID: Double] }`. Resting is accrued up to "now" for today.
- Optional daily goal in profile (default `nil`; UI hides the goal bar when unset).

Checks: known profile gives the expected BMR to ±1 kcal; 60 minutes at 150 bpm for a 30-year-old 75 kg male gives ≈ 650–700 kcal from Keytel; all-gap day returns resting only.

### Phase 4 — Workout auto-detection

Tasks
- `ActivityDetector` as a state machine fed one `MinuteHR?` at a time (works for both live and history):
  - **Start**: ≥ 5 of the last 6 minutes have HR ≥ 60% of max (Z2 floor). Candidate start = first of those minutes.
  - **End**: 5 consecutive minutes below the threshold, or a 10-minute data gap. End = last minute above threshold.
  - **Keep** only if duration ≥ 10 minutes.
  - **Type guess**: average ≥ 70% max and low minute-to-minute variability → Running; 50–65% → Walking; high variability with repeated rises and drops → Strength; otherwise Other. Store a `confidence` 0…1. Cycling is never guessed (HR alone can't tell it from running); the user picks it.
- `DetectedActivity { id, start, end, guessedType, confidence, status: pending|confirmed|dismissed, metrics }` in a new SQLite table `detected_activities`.
- Ignore windows that overlap a manual workout by more than 50%. Deduplicate: a new detection overlapping an existing one updates it instead of inserting.
- Run the detector (a) incrementally on the live stream and (b) over the window since the last sync after each history sync completes.
- Confirm: converts to a `Workout` (`source = .detected`, readings from the timeline, metrics computed) and sets status `confirmed`. Change type: confirm with another type. Dismiss: sets `dismissed`; never re-detect the same window.
- Add `source: WorkoutSource` (`manual` / `detected`, default `manual`) to `Workout`.

Checks: synthetic run (5 min warm-up, 20 min at 75%, 5 min cool-down) detected once with correct bounds ±1 minute; a 6-minute stair climb is not detected; a manual workout over the same window suppresses detection; re-running over the same data does not duplicate.

### Phase 5 — Sleep

Tasks
- Window search: for the night ending on day D, look between 18:00 on D−1 and 14:00 on D.
- Daytime baseline = median HR of awake minutes on D−1 (fallback: median of the whole window).
- **Onset**: first minute where the 10-minute rolling median drops below `baseline − 10 bpm` (constant) and stays below it for 20 minutes. **Wake**: last minute before the rolling median stays above the threshold for 20 minutes.
- **Awake bouts** inside the window: ≥ 3 consecutive minutes above `sleepingMedian + 15 bpm`.
- **Stage estimate** (HR-only, experimental): within asleep minutes, by percentile of HR and local variability: lowest-HR, low-variability stretches → Deep; highest-variability non-awake stretches → REM; the rest → Light. Apply a 5-minute minimum segment length. Set `stagesAreEstimate = true`. If fewer than 80% of minutes in the window have data, return the session without stages.
- `SleepSession { start, end, inBed, asleep, awake, stages: [SleepSegment]?, sleepingHR, lowestHR, rmssd?, coverage }`.
- Sleep need: `baseline (7.5 h, profile-configurable) + strainAdjustment (previous day strain × 3 min) + debt (50% of shortfall over the last 3 nights, capped at 2 h)`. Performance = asleep / need, capped at 100%.
- Consistency: 100 − average deviation (minutes) of the last 4 nights' onset and wake from their mean, scaled and clamped to 0…100.
- Store in table `sleeps` keyed by wake date; recompute after each sync covering the window.

Checks: synthetic night (awake 70 bpm → 52–58 bpm for 7 h with two 5-minute awakenings → 68 bpm) detects onset/wake ±5 minutes and two awake bouts; low coverage returns no stages; need and performance arithmetic is exact for fixed inputs.

### Phase 6 — Recovery

Tasks
- Inputs per night: sleeping RHR (lowest 5-minute average while asleep), RMSSD if available, sleep performance.
- Baseline: rolling 14-night mean and standard deviation of each input. Require ≥ 4 nights, otherwise state `calibrating(nightsSoFar)`.
- Score: z-scores (RHR inverted), weights RHR 0.5, HRV 0.3, sleep 0.2. Without HRV, reweight RHR 0.7, sleep 0.3. Map to 0–100 with a logistic curve centred on 58. Bands: ≥ 67 green, 34–66 yellow, < 34 red.
- `RecoveryResult { score, band, inputs, usedHRV }`.

Checks: inputs equal to baseline give ≈ 58; worse RHR lowers the score; fewer than 4 nights returns calibrating.

### Phase 7 — Notifications

Tasks
- `NotificationService` wrapping `UNUserNotificationCenter`. Request authorization the first time the user turns on a notification toggle, not at launch.
- Category `WORKOUT_DETECTED` with actions Confirm (foreground: no) and Dismiss (destructive). Handle them in a `UNUserNotificationCenterDelegate` set at app launch, calling `HealthEngine.confirm/dismiss`.
- Notifications:
  - **Workout detected** — when a detection becomes ≥ 10 minutes long and pending. One per detection (thread id = detection id).
  - **Workout saved** — on finish or confirm: type, duration, strain, calories.
  - **Sleep recorded** — when a new `SleepSession` is stored: duration and performance.
- Settings in `UserDefaults`: `notifyDetections`, `notifyWorkoutSaved`, `notifySleep` (default on once permission is granted).
- History-based detections and sleeps found during a sync are posted only if they ended within the last 12 hours, to avoid a burst after a long gap.

Checks (manual, on device): each notification appears once; Confirm from the lock screen creates the workout; denied permission degrades silently.

### Phase 8 — Live Activity and Dynamic Island

Tasks
- `project.yml`:
  - app `info.properties`: `NSSupportsLiveActivities: true`.
  - new target `TrackerWidgets` (`type: app-extension`, `platform: iOS`, sources `TrackerWidgets` and `Tracker/Shared`, `NSExtension.NSExtensionPointIdentifier: com.apple.widgetkit-extension`), embedded in `PersonalTracker` via `dependencies`.
  - add `Tracker/Shared` to the app target too.
- `WorkoutActivityAttributes` (shared): static `workoutType`, `startDate`; `ContentState { bpm: Int?, zone: Int?, calories: Int, strain: Double, pausedAt: Date?, pausedSeconds: Double, isStale: Bool }`.
- Widget UI: lock screen (type, elapsed via `Text(timerInterval:)` so it ticks without updates, BPM, zone, calories, strain, Pause/End buttons); Dynamic Island compact (activity glyph + BPM), minimal (BPM), expanded (type, elapsed, BPM, zone, calories). Follow the design canvas colours: HR `#FF4D5E`, calories `#FFB020`, strain `#3B9EFF`, zones blue/green/yellow/orange/red.
- `WorkoutIntents.swift` (shared): `PauseWorkoutIntent`, `EndWorkoutIntent` conforming to `LiveActivityIntent`, calling into the app (they run in the app process).
- `WorkoutActivityController`: start on workout start (if the "Show on lock screen" setting is on and `ActivityAuthorizationInfo().areActivitiesEnabled`), update at most every 5 s or on zone change / pause, mark `isStale` when no HR for 15 s, end on finish with a final state and `dismissalPolicy: .after(+15 min)`. On launch, end any orphaned activities whose workout no longer exists.

Checks (manual): start a workout → lock screen shows it; Pause from the lock screen pauses the in-app timer; End finishes and saves; killing the app does not leave a stuck activity after relaunch.

### Phase 9 — Wiring and minimal UI exposure

Tasks
- `HealthEngine` publishes: `today: DailySummary` (strain, calories breakdown, time in zones, current zone), `lastSleep`, `recovery`, `pendingDetections`, `activeWorkoutMetrics` (live calories/strain/zone during a workout). Recompute: live — at most every 30 s; history — after sync; date rollover — at local midnight and on app foreground.
- Replace the current "Trends" placeholder text and add plain sections on Today (strain, calories, last sleep, pending detections with Confirm/Dismiss) so everything can be tested before the visual redesign.
- Settings rows in Device: profile, detection on/off, lock screen on/off, notification toggles, max HR.
- Update `README.md`: features, the estimate disclaimers, and the extended test command.

Acceptance: a fresh install with no data shows only empty/calibrating states; after a workout and a sync, every metric is populated and consistent between Today, the workout summary, the notification and the Live Activity.

## 6. Order and dependencies

```
0 Profile ─┬─▶ 2 Zones/Strain ─┬─▶ 4 Detection ─▶ 7 Notifications
           │                   └─▶ 3 Calories
1 Timeline ┴─▶ 5 Sleep ─▶ 6 Recovery
2,3 ─▶ 8 Live Activity      all ─▶ 9 Wiring
```

Phases 2–3 and 5 can proceed in parallel after 0–1. Phase 8 needs only 2–3.

## 7. Testing

- Extend `Tests/main.swift` with the checks listed per phase, using synthetic minute series built by a small helper (`makeSeries(segments: [(minutes, bpm)])`).
- Updated command (README):

```bash
swiftc Tracker/FrameDecoder.swift Tracker/HistoryProtocol.swift Tracker/HistoryStore.swift Tracker/LiveHeartRate.swift Tracker/Health/*.swift Tests/main.swift -o /tmp/whoop-protocol-checks && /tmp/whoop-protocol-checks
```

  Files that import SwiftUI, ActivityKit or UserNotifications (`HealthEngine`, `NotificationService`, `WorkoutActivityController`) must stay out of this command; keep them out of the pure files' dependency graph.
- Build the app with `xcodegen generate` and `xcodebuild -scheme PersonalTracker -destination 'generic/platform=iOS Simulator' build` after every phase.
- Manual on-device checklist for Phases 7–8 (Bluetooth and Live Activities need a real device).

## 8. Out of scope

- The visual redesign itself (see the design canvas; separate task).
- HealthKit export, cloud backup, multi-device.
- Decoding accelerometer, temperature or SpO₂ from raw frames (worth a separate research task; would improve sleep and detection).
- Always-on background streaming.

## 9. Definition of done

- All phase checks pass in the command-line test binary; the app and widget extension build.
- No screen shows a value that wasn't computed from stored samples; all estimates are labelled.
- Existing users' `workouts.json` and `history.sqlite` load without loss.
- README documents features, limits and the test command.

> UI side: see `docs/frontend-integration.md` for the `DisplayStore` properties and closures the engines must feed.
