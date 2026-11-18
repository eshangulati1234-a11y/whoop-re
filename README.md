# Personal WHOOP 4 Tracker

Native iOS 17+ foundation. No subscription, account or server.

## Build

Run `xcodegen generate`, open PersonalTracker.xcodeproj, select your signing team and an iPhone, then run. Disconnect the official app before attempting connection.

## Current status

Native SwiftUI app with a WHOOP-style UI (Home, Sleep, Live, Device). Band connection, length/CRC-validated frame decoding and experimental historical sync are unchanged: sync saves each batch before acknowledging its exact token and supports cancellation and idle timeout. SQLite (schema v3) keeps raw frames, deduplicated heart-rate samples, per-minute live readings, detected activities and sleep sessions.

`HealthEngine` turns that data into what the UI shows: live heart rate, calories, strain, zones, automatic workout detection (with a review prompt and notification), last night's sleep, a recovery estimate, and a lock-screen Live Activity / Dynamic Island for workouts. Foreground and reconnect auto-sync follow `SyncPolicy`; a background refresh task runs a short sync when iOS allows.

**All calories, strain, sleep stages, sleep need and recovery numbers are heart-rate-only estimates, not measurements.** Calories use Keytel (age, weight, sex needed, so a profile is required) plus Mifflin-St Jeor resting burn. Strain is a TRIMP-style load. Sleep is found from a sustained drop in heart rate and its stages are a hypothesis (omitted when coverage is low). Recovery is a z-score against your own recent nights and shows "calibrating" until enough nights exist. Nothing is invented: missing data shows an empty state.

Not verified: behaviour on a physical band, notification actions from a locked device, background refresh timing and battery impact. Storage uses the system SQLite API on the main executor and should move to a dedicated executor before large-scale use. HealthKit, backup and editing of past workouts are not implemented. Only the narrow history-sync command set is enabled. No flash erase, firmware, read-pointer, clock or forced optical writes are exposed.

Protocol reference: https://github.com/OpenStrap/research/blob/main/PROTOCOL.md . Public research is not evidence of compatibility with your firmware.

## Launch, setup and calibration

The app opens on a launch screen that fades to Home once the band connects (or after a short timeout, or straight away if no band has ever been paired). Home shows a setup checklist until the band has synced, then a calibration card.

Records are decoded from history (schema v5): heart rate, RR intervals, gravity, optical and skin channels. Rules in use: a night counts with at least 4 h asleep and 80% measured; Recovery unlocks after 4 valid nights and is labelled Early until 14; missed nights pause progress and a baseline lapses only after 14 days without one. Zones use heart-rate reserve (40/60/70/80/90%) with a provisional resting rate of 70 until measured, drifting at most 2 bpm a week. Strain is shown from day one, tagged Provisional. Daytime naps (30–180 min, 08:00–20:00, measured stillness) are detected; ones under 60 min need your confirmation.

Honest limits: RR data from the band is sparse and unvalidated, so HRV is an estimate. Respiratory rate and blood oxygen are not available (red/IR channels are nearly constant). All scores are experimental estimates. Verifying sync of a long backlog and real overnight accuracy needs the band worn.

## Checks

`swiftc Tracker/FrameDecoder.swift Tracker/HistoryProtocol.swift Tracker/HistoryStore.swift Tracker/LiveHeartRate.swift Tracker/Health/*.swift Tests/main.swift -o /tmp/whoop-protocol-checks`

`/tmp/whoop-protocol-checks`

Tests cover standard CRC vectors, reference wire fixtures, all frame split positions, corrupt payload rejection, embedded start bytes, truncated records, duplicate batches, database reopening and transfer replay. They also cover the profile, calorie, strain, detection, sleep, recovery and sync-policy engines and the v2 to v3 database migration. They do not verify physical-band behavior or the complete Bluetooth state machine.

## Band clock

Each time the band connects the app reads its clock (GET_CLOCK, read-only). If it differs from phone time by more than 30 seconds, it sends SET_CLOCK with a five-byte timestamp/commit payload and reads it back; this repeats at most once an hour. An unreadable clock is reported but never overwritten. Device → Band clock → Check now repeats the check. Firmware compatibility is unverified until tested on the band, and missing unsaved history cannot be recovered. Wear for 5–10 minutes after a repair, then sync to check for actual sensor records. Reference: https://github.com/andyguzmaneth/whoop4-ble/blob/main/examples/01_fix_rtc.py

## Live HR and manual workouts

Today subscribes to the standard Heart Rate Service (180D/2A37), displays a 120-reading chart and marks readings stale after 10 seconds. Subscriptions stop when Today is hidden or the app becomes inactive, except during an active workout. Requires firmware exposing the standard service; no proprietary stream activation fallback is implemented yet. RR intervals feed the per-minute RMSSD stored with live readings.

Manual running/cycling/walking/strength/other workouts support pause, resume and finish. Workouts are stored atomically in protected local JSON and an unfinished session is restored on launch. Readings checkpoint every ten samples. Detected workouts can be confirmed into the same list. HealthKit, backups, full session editing and dedicated storage execution remain unfinished.

## Debug flags (DEBUG builds)

`-previewData` shows every screen populated from in-memory sample data. `-demoHistory` writes two weeks of synthetic history to a throwaway temp directory, runs the real engines over it and simulates live heart rate, so the full pipeline can be seen without a band. Neither touches your real data.
