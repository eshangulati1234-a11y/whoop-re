# Frontend integration (SwiftUI UI ↔ health engines)

The redesigned UI lives in `Tracker/UI/`. It never computes health metrics and never invents values.
It renders a display layer, `DisplayStore` (`Tracker/UI/DisplayStore.swift`), whose fields are optional.
A `nil` / empty value shows an honest empty state ("—", "No data", "Calibrating").

## What is real today
- Live heart rate (`BandManager.liveSamples` → `DisplayStore.current` / `trace`)
- Manual workouts (`startWorkout` / `pauseWorkout` / `finishWorkout`, `band.workouts`, `band.activeWorkout`)
- History sync (`band.samples`, `band.lastSync`) and connection state

## What the health engine must provide
Set these on the `DisplayStore` instance (main actor). Types are in `Tracker/UI/DisplayModels.swift`.

| Property | Type | Shown on |
|---|---|---|
| `day` | `DisplayDay` (strain 0–21, recovery + band, `recoveryCalibratingNights`, `sleepPerformance` 0–1, `calories`) | Home rings, Calories |
| `lastSleep` | `DisplaySleep?` (`segments == nil` when coverage is too low for stages) | Home, Sleep |
| `detections` | `[DisplayDetection]` pending auto-detected workouts | Home activities, Detected review |
| `workoutMetrics` | `[Workout.ID: DisplayWorkoutMetrics]` calories / strain per saved workout | Home, Summary |
| `activeMetrics` | `DisplayWorkoutMetrics?` live calories / strain | Active workout |

Closures the UI calls (nil until wired):
- `confirmDetection: ((DisplayDetection, String) -> Void)?` — user saved a detection with the chosen activity type.
- `dismissDetection: ((DisplayDetection) -> Void)?` — user chose "Not a workout".

All calorie / sleep / strain / recovery numbers are estimates. The UI labels them accordingly; keep that when adding copy.

## Settings keys (UserDefaults / @AppStorage)
- `detectionEnabled` (Bool, default true) — workout detection + notifications
- `liveActivityEnabled` (Bool, default true) — lock-screen Live Activity
- `notifyDetections`, `notifyWorkoutSaved`, `notifySleep` (Bool, default true)
- `userProfile` (JSON) — age, weight, height, sex and optional max HR override, edited in Device → Profile. `ZoneConfig.maxHR` reads it (override, else age estimate, else `uiMaxHR`, else 190).
- `uiMaxHR` (Int) — legacy fallback only.

## Wiring
`RootView` owns a `DisplayStore` and a `HealthEngine` (`Tracker/Services/`) and attaches both to `BandManager`. The engine assigns the store's properties and its confirm/dismiss closures; views never compute health values.

## Preview data (DEBUG only)
Launch with `-previewData` to see every screen populated without a band (`Tracker/UI/PreviewData.swift`, compiled out of release builds, nothing persisted):

```bash
xcrun simctl launch --terminate-running-process booted personal.whooptracker -previewData
```

Launch with `-demoHistory` instead to run the real engines over synthetic history (temporary directory, simulated live HR).

## Live Activity
`TrackerWidgets/` holds the lock-screen and Dynamic Island UI; shared types live in `Tracker/Shared/`. Run `xcodegen generate` after adding files.

## Not built yet
App icon and asset catalog.
