# Implementation plan: transport, full record decode, sleep, calibration

Written 10 Nov 2026 for an implementing model (Sonnet 5.5). Work through the phases in order. Each phase ends with a check that must pass before the next one starts.

Background reading, in this repo:
- `docs/bluetooth-reliability-review.md` (why the transport changes)
- `docs/calibration-review.md` (why the calibration changes, WHOOP sources)

## Ground rules

- The project is **not a git repository**. Do not commit or run `git init` unless the user asks.
- Another tool (Codex) has edited this project. Read every file before editing it; do not assume this plan's line references are still exact.
- All health numbers are estimates. Never invent a value: missing data shows an empty or "not enough data" state.
- Do not send any band command that this plan does not list. No firmware, flash-erase, read-pointer, LED-drive or haptic commands.
- New Swift files need `xcodegen generate` before building.
- Pure logic goes in `Tracker/Health/` (compiled into the CLI tests). Anything touching CoreBluetooth, SwiftUI or UIKit stays out of that folder.
- Every phase adds tests to `Tests/main.swift` using the existing `check(_:_:)` helper. Existing tests that encode old rules (recovery after 7 nights, strict 7-day strain gate, old zone maths) must be updated, not deleted, and the change noted in the final report.
- UI uses the existing components in `Tracker/UI/Components.swift` (`Card`, `PillButtonStyle`, `CardPressStyle`, `Haptics`, `.screenBackground()`, `sectionLabel`) and `Palette`/`Typo` from `Tracker/UI/Theme.swift`. Any scrolling screen under the tab bar must use `.screenBackground()` so its bottom clears the bar.
- Report honestly at the end of each phase: what passed, what was not verified on the physical band.

### Commands

Set `S` to a scratch directory outside the project.

```bash
swiftc Tracker/FrameDecoder.swift Tracker/HistoryProtocol.swift Tracker/HistoryStore.swift Tracker/LiveHeartRate.swift Tracker/Health/*.swift Tests/main.swift -o $S/checks && $S/checks
```

```bash
xcodegen generate
```

```bash
xcodebuild -project PersonalTracker.xcodeproj -scheme PersonalTracker -destination 'id=2DFF6148-09E6-4300-B2B4-84C9B29AD3EB' -derivedDataPath $S/dd CODE_SIGNING_ALLOWED=NO build
```

```bash
xcodebuild -project PersonalTracker.xcodeproj -scheme PersonalTracker -destination 'id=00008150-000C2D160C85401C' -derivedDataPath $S/ddev -allowProvisioningUpdates build
```

```bash
xcrun devicectl device install app --device 00008150-000C2D160C85401C $S/ddev/Build/Products/Debug-iphoneos/PersonalTracker.app
```

```bash
xcrun devicectl device copy from --device 00008150-000C2D160C85401C --domain-type appDataContainer --domain-identifier personal.whooptracker --source "Library/Application Support/ble-log.txt" --destination $S/ble-log.txt
```

The same `copy from` command with `history.sqlite` as the source pulls the phone's database for offline checks. Treat it as private health data: keep it in `$S`, never upload it.

Simulator launch flags: `-previewData` (in-memory sample data) and `-demoHistory` (synthetic history through the real engines).

### Where things are

| Area | File |
|---|---|
| Bluetooth manager (`BandManager`, `BLELog`) | `Tracker/TrackerApp.swift` |
| Frame building and record parsing | `Tracker/HistoryProtocol.swift`, `Tracker/FrameDecoder.swift` |
| SQLite store (schema v4) | `Tracker/HistoryStore.swift` |
| Minute series, RMSSD | `Tracker/Health/HRTimeline.swift` |
| Sleep, recovery, zones, calibration engines | `Tracker/Health/*.swift` |
| Orchestration | `Tracker/Services/HealthEngine.swift`, `Tracker/Services/Personalization.swift` |
| Screens | `Tracker/UI/*.swift` |

In this codebase a "frame" passed to `HistoryProtocol` is the **inner** record: the full wire frame minus its first 4 bytes. Community offsets quoted as "frame offset N" are therefore **inner offset N − 4**. Heart rate at wire offset 21 is `inner[17]`, which is what the code already reads.

---

## Evidence from the 10 Nov device log (read before Phases 0 and 1)

Source: `ble-log.txt` and the `frames` table of `history.sqlite`, both pulled from the phone after about 50 minutes of use. The first draft of Phase 1 assumed syncs failed in the command preflight. The data shows otherwise.

What the data shows:
- **The preflight always succeeds.** Every session starts with command replies for hello, name, range and alarm, all `result=1`, and `history` is acknowledged as pending (`result=2`). The log's `step history` means the stall comes *after* that.
- **Most "stalled" syncs delivered data.** Sessions at 18:02, 18:14, 18:30 and 18:32 delivered 340, 150, 348 and 350 records, in chunks of about 50 records roughly 1.8 s apart. Each ended on a history-END marker, and then the band said nothing more. No COMPLETE marker arrived, and the last record was 8 to 28 minutes behind real time, so more data was waiting.
- **Before 18:00 the same transfer finished.** Sessions 0 to 6 (17:40 to 17:50) all ended with COMPLETE and caught up to within about 10 s of real time, one of them across 19 chunks. The change after 18:00 is a backlog of minutes instead of seconds, and syncs that stop partway through it.
- **A restart resumes where it stopped.** The first END of the 18:14 session carries the same cursor (105207) as the last END of the 18:02 session. So a new `history` command replays the last un-acknowledged chunk and then moves on. Re-storing it is harmless because inserts ignore duplicates. No data was lost: cursors only ever advanced, by 5 per 50-record chunk.
- **Some retries return an empty chunk.** At 18:08 and 18:28 the band answered with START then END, no records, repeating the previous cursor, and went quiet. That is the band re-announcing a chunk it never saw acknowledged.
- **The link is not dropping.** The only disconnect in the log is the 5:46 setup timeout. The earlier reconnect loop is gone.
- **The log marks failure while data was flowing.** Those four syncs were reported as stalled even though they made progress. The app should say "partly synced, N minutes behind".

What this rules out: the preflight, the keep-alive and raw stream as the *current* cause, and link loss.

What it does not yet settle, because the phone does not record what it *sends*:
1. Did the acknowledgement for the last END leave the phone, and did the write complete?
2. Does the band stop after some number of chunks per session unless the client reconnects or re-requests (a band-side limit)?
3. Do frequent sessions (every 60 s in the foreground, plus retries) make the band less willing to stream? WHOOP's own app backfills every 15 minutes according to the noop project; noop's own client also re-runs nothing mid-offload.

Defects found in the current build, from the same log:
- The "band is silent" detector counts standard heart-rate notifications as activity (`lastFrameAt` is set before the 2A37 branch in `didUpdateValueFor`), so a live screen hides a dead history stream. This is also why a stall sometimes took 96 s to be noticed.
- "Link check ok" can be satisfied by a heart-rate notification instead of a command reply, so it proves less than it says.
- At 18:30:05 a stall sent abort, a link probe and a brand-new sync within one second.
- The auto-sync backoff is measured from the last *auto* attempt, so a manual sync that stalls is followed at once by an auto sync.
- One stall took 604 s (18:14 to 18:24), far past the 120 s limit, so the app was almost certainly suspended with timers stopped. The log does not record app launches or suspensions. The relaunch at 18:30:40 (a connect with no disconnect line before it) went unrecorded.

---

## Phase 0: Instrumentation

Goal: every sync, drop and stale reading can be explained from the log alone.

In `BandManager`, add `log.add(...)` lines (the `BLELog` class already exists) for:
- link ready, with seconds since connect;
- each command sent during sync and the time to its reply;
- clock check result (correct, corrected, unreadable) and drift in seconds;
- sync end: records, rejected records, chunks, duration, bytes;
- disconnect with the CoreBluetooth error code and domain;
- app active/inactive;
- 2A37 subscribe state changes, and "live HR stale for N s" once per stale episode;
- bytes received per packet type over each sync (types 0x28, 0x2b, 0x2f, 0x30, 0x31, 0x32);
- **the acknowledgement chain, one line per chunk:** END received (cursor, records in chunk) → ACK handed to the writer → write confirmed by CoreBluetooth (time) → next START or COMPLETE received (time since ACK), or "no continuation after 5 s";
- every transmitted frame, not just received ones: add a table `tx_frames(time REAL, payload BLOB)` (ring of the last 2,000) so a pulled database shows exactly what was sent;
- app launches with the previous run's end state ("launched; last run ended: unknown/backgrounded/terminated"), and scene-phase changes, so suspensions and relaunches are visible.

Also read and log the firmware version once per connection with command 7 (`REPORT_VERSION_INFO`, body `[0]`); store the raw reply hex in the log, do not gate anything on it.

Raise the log limit to 1,000 lines.

**Check:** simulator build passes; on the phone, one connect and sync produces all the line types above.

## Phase 1: Minimal, resilient transport

All in `Tracker/TrackerApp.swift` and `Tracker/HistoryProtocol.swift`.

1. **Connect stays pending.** Remove the 20 s cancel in `watchConnection` for the connect step. Call `central.connect(peripheral)` once and leave it pending; iOS completes it when the band is in range. Keep a 20 s watchdog only for the steps *after* `didConnect` (service and characteristic discovery, notifications enabled). `scheduleReconnect` then just calls `connect` again immediately after a disconnect, with no growing delay, because a pending connect costs nothing.
2. **Once-per-connection handshake**, run when the link becomes ready, guarded by a `handshakeDone` flag reset in `resetSession`:
   - command 63 (`rawRealtime`) body `[0]` to make sure the raw stream is off;
   - `setClock` with the existing 5-byte body **only if** the last clock check found drift over 30 s or no check has ever succeeded;
   - nothing in the handshake waits for a reply.
3. **Run the preflight once per connection, not once per sync.** The preflight itself works (see the evidence section), so this is a cleanup based on noop's report that re-running the handshake mid-offload can stop the stream, not the fix for the stalls. Send hello, name and range once when the link becomes ready (store the range reply for the log), then every sync sends only `history` (0x16, body `[0]`). Drop the `alarm` command entirely; it is not needed. Keep `pendingCommand` handling for `history`.
4. **Clock read inside the transfer.** After the first type-0x2f or 0x31 frame of a sync arrives, send `getClock` (body `[0]`) once. Handle its reply with the existing `handleClockReading`, but never start a repair mid-sync: record the drift and run `repairClock()` after the sync completes. Remove the on-connect `checkClock()` call and its 8 s timer; keep the manual "Check now" button, which now says "Checked during the next sync" when idle.
5. **Remove `linkValid` keep-alive** (`startLinkWatch`). Keep `probeLink()` only for the after-stall check.
6. **Remove commands 3 (`realtimeHR`), 63-on and 107 (`optical`) from live HR.** `updateStreaming()` only subscribes or unsubscribes 2A37. Delete `proprietaryStreaming` and the "pause live during sync" branch: leave 2A37 subscribed during a sync.
7. **Session identity.** Add `connectionGeneration: Int`, incremented in `resetSession`. Stamp it on the in-flight sync; drop any frame handled when the stamp differs.
8. **Sequence wrap.** With steps 3–6 the app sends a handful of commands per connection, so wrap is no longer reachable in practice. Still, clear `pendingSequence` on every `resetSession` (already done) and never match a reply when `pendingCommand` is nil.
9. **Watchdog values:** keep 20 s without a frame *from the proprietary characteristics* (0x24, 0x2f, 0x30, 0x31, 0x32) or 120 s without a 0x2f/0x31 frame. Set `lastFrameAt` only for those characteristics, never for 2A37. Use a monotonic clock (`ContinuousClock` or `ProcessInfo.systemUptime`) and, if the app was suspended during the sync (scene phase), end the sync quietly and resume it on return instead of reporting a stall.
10. **Link state.** With live left on during sync, `LinkState.syncing` is only shown when there is no fresh reading *and* a sync is running.
11. **Resume the acknowledgement chain instead of waiting.** After each ACK, if no START, record or COMPLETE arrives within 5 s: re-send the *same* ACK (same cursor and wrap word, so it is idempotent) once. If another 5 s passes with nothing, send `abort` (0x14), wait 2 s, then send `history` again. The band replays the last un-acknowledged chunk, so nothing is lost and duplicates are ignored on insert. Log each step.
12. **Keep going while progress is made.** Define progress as "the END cursor advanced during this attempt". After a stall that made progress, restart at once (after the 2 s above); a transfer ends only on COMPLETE. Only an attempt with **no** cursor advance counts as a failure and starts the 2 / 5 / 15 minute backoff. Cap one sync at 20 attempts. This turns the log's stop-start pattern, about 350 records per attempt, into one catch-up that finishes in seconds to a minute or two.
13. **Say what actually happened.** A stall that made progress shows "Synced up to HH:MM · N min behind, continuing", never "timed out". Show the plain "paused, will retry in N min" text only for a no-progress failure. Home and Device show the lag in minutes while there is a backlog.
14. **Fewer, calmer sessions.** Change `foregroundSyncAge` from 60 s to 15 minutes (the cadence noop reports for WHOOP's own backfill). A manual sync, opening the app after more than 15 minutes, and pull-to-refresh still start one immediately. Treat this as an experiment: record sessions per hour in the log, and keep 15 minutes only if the Phase 1 check passes with it.
15. **No overlapping control traffic.** After a stall or `abort`, do not send a probe or start another sync for 2 s. A probe must wait for a command reply of type 0x24, not any notification. Measure the auto-sync backoff from the last *failure of any kind* (manual or automatic), not from the last auto attempt.
16. **Persist without blocking the radio.** Writing a chunk (about 100 frames) must not delay the ACK: move `persist` to a serial queue with prepared statements (see Phase 2 step 5) and send the ACK as soon as the commit returns. Log commit time per chunk; anything over 100 ms is a finding.

Data-safety rules that must still hold after the edit (add tests where the logic is pure):
- a chunk is stored with `historyStore.persist` before its `acknowledge` is sent;
- the 8-byte token from `HistoryProtocol.token` is echoed byte-for-byte;
- a chunk interrupted by a stall or disconnect is dropped unacknowledged;
- a failed write stops the sync with no acknowledgement and a plain error.

Add a small table `sync_cursors(time REAL, token BLOB, records INTEGER)` (part of the Phase 2 migration) and insert one row per acknowledged chunk.

**Check (provisional targets, measured from the log over 48 h of normal wear):**
- at least 95% of syncs end on COMPLETE (not "stalled"), and a backlog of 20 minutes or more drains to COMPLETE in one sync, automatically, without a manual retry;
- the log shows, for every chunk, ACK written and next chunk received within 3 s, or the resume steps from step 11;
- a sync that restarts after a stall makes progress (cursor advances) at least 9 times in 10;
- zero app-initiated disconnects while the band is in range;
- with the app in the background and the band brought back after 30 minutes away, it reconnects and syncs without opening the app in 9 of 10 tries;
- on a live screen with the band on the wrist, no gap over 5 s between readings in 30 minutes;
- no type-0x2b bytes logged.

If, with steps 11 to 16 in place, syncs still stop mid-transfer, use the Phase 0 trace to decide, and report which case applies before changing anything else:
- the ACK was written and confirmed but no chunk followed, repeatedly: the band limits chunks per session, so keep the restart-on-progress loop and report the observed chunk limit;
- the ACK was never written or the write was never confirmed: this is a phone-side defect in the write queue (`awaitingWrite` stuck, or `canSendWriteWithoutResponse` false with no ready callback), so fix that first;
- the stalls cluster in periods when the app was suspended: this is iOS scheduling, so rely on the restart-on-resume behaviour and the background-refresh path.

Evidence that would justify another look at the band itself: a `GET_DATA_RANGE` reply showing newer records than the cursor, while `history` keeps returning empty chunks for longer than 15 minutes. noop describes this as a "stuck strap" and recovers with command 97 (exit high-frequency sync) and a clock set; a reboot from the official app is WHOOP's own advice for other symptoms. Do not add either unprompted; ask the user.

## Phase 2: Decode and store the whole history record

Today only time and heart rate are read. The 96-byte v24 record also carries beat-to-beat intervals, motion, skin contact and raw optical values. Offsets below are **inner** offsets (wire offset − 4), from the noop v24 map.

| Inner offset | Type | Field |
|---:|---|---|
| 1 | u8 | record version (24) |
| 3 | u32 LE | record counter |
| 7 | u32 LE | Unix seconds |
| 17 | u8 | heart rate, bpm |
| 18 | u8 | RR count (0–4) |
| 19, 21, 23, 25 | u16 LE | RR intervals, ms; 0 = none |
| 29, 31 | u16 LE | raw optical scalars (green, red/IR labelled) |
| 36, 40, 44 | f32 LE | gravity vector x, y, z in g |
| 51 | u8 | skin contact; 0 = off wrist |
| 64, 66 | u16 LE | raw red and IR values ("SpO2-adjacent", not a percentage) |
| 68 | u16 LE | skin temperature, raw ADC |
| 76 | u16 LE | respiration-adjacent raw |
| 78 | u16 LE | signal-quality word |

Steps:
1. `Tracker/HistoryProtocol.swift`: add `struct HistoryRecord` with those fields and `static func record(_ inner: [UInt8]) -> HistoryRecord?`. Accept only length 96 and version 24. Validate: time in the existing plausible range; RR count ≤ 4; each RR 250–2500 ms else dropped; gravity magnitude 0.5–1.5 g else motion is nil. Keep `sample(_:device:)` working by building it from `record`.
2. `Tracker/HistoryStore.swift`: migrate to **schema v5** in one transaction:
   - `records(time INTEGER PRIMARY KEY, bpm INTEGER, rr BLOB, gx REAL, gy REAL, gz REAL, contact INTEGER, red INTEGER, ir INTEGER, skin_raw INTEGER, resp_raw INTEGER, quality INTEGER)`;
   - `history_minutes(minute INTEGER PRIMARY KEY, bpm_avg REAL, bpm_min INTEGER, bpm_max INTEGER, count INTEGER, rr_rmssd REAL, rr_count INTEGER, motion REAL, contact REAL, red_ir REAL, skin_raw REAL)`;
   - `sync_cursors` from Phase 1.
   `persist` inserts into `records` as well as `samples`. Add `rebuildRecords()` that replays the stored `frames` table into `records` (the existing `replaySavedFrames` shows the pattern); run it once after migration, off the main thread.
3. **Minute aggregation** (pure, in `Tracker/Health/HRTimeline.swift`): `static func aggregate(_ records: [HistoryRecord]) -> [HistoryMinute]`.
   - `motion` = mean absolute change of the gravity vector between consecutive seconds, in milli-g.
   - `contact` = share of seconds on the wrist.
   - `rr_rmssd` = RMSSD of successive RR differences inside the minute, after dropping any interval that differs from the previous one by more than 20%; needs ≥ 20 valid intervals.
   - `red_ir` = mean of red ÷ IR for seconds with both non-zero.
   Recompute affected minutes after each sync chunk.
4. `HRTimeline.minuteSeries` reads `history_minutes` so `MinuteHR.rmssd` and `validRRCount` are filled from history, and add `motion` and `contact` to `MinuteHR` (optional, so old code compiles).
5. Move `persist` and aggregation off the main thread: give `HistoryStore` a serial queue and make the Bluetooth path `await` the write before sending the acknowledgement. Use prepared statements instead of building SQL strings.

**Validation against the phone's own data** (pull `history.sqlite` to `$S`, run a small throwaway script there, do not add it to the app):
- ≥ 95% of 96-byte records parse as v24;
- for records with ≥ 2 RR values, `60000 / mean(RR)` is within 10% of the stored heart rate for ≥ 90% of them;
- gravity magnitude is 0.9–1.1 g for ≥ 90% of on-wrist records;
- contact is 0 for a period the user confirms the band was off (ask them for one).

If the RR check fails, stop and report: Phases 4 and 5 depend on it. If only motion or contact fails, continue with that field left nil.

**Check:** CLI tests for the parser (a hand-built record with known values, truncated record, bad version, bad RR), migration v4 → v5 on a temp database, and aggregation maths.

## Phase 3: Device setup

Goal: a first-run flow that leaves the band and the algorithms correctly set up, and a clear state when they are not.

1. `Tracker/Health/SetupState.swift` (pure): `struct SetupState` with `profileComplete`, `bandPaired`, `clockVerified`, `firstSyncDone`, `wornLastNight`, and `var remaining: [SetupStep]`.
2. Profile gains optional fields already present (max HR, resting HR, sleep need) plus **wrist** (left/right, stored only) and **usual bedtime and wake time** (seeds sleep consistency and the nap window until data exists).
3. New `Tracker/UI/SetupView.swift`: a checklist card shown on Home while `remaining` is not empty. Rows: Add your profile → Connect your band → Band clock checked → First sync → Wear it tonight. Each row is tappable and opens the relevant screen. Completed rows show a tick; the current row is highlighted.
4. Device screen: show firmware version, last sync time and record count, band battery if a battery event (type 0x30, event 3) was seen in the last sync, and "Worn now / Off wrist" from the latest contact value.
5. Other-app warning: if a connect has been pending for over 2 minutes with Bluetooth on, show "If the official WHOOP app is open on any device, close it. The band talks to one app at a time."

**Check:** simulator screenshots of the checklist at 0, 2 and all steps complete (add a DEBUG flag `-setupStage N`).

## Phase 4: Sleep, naps and overnight vitals

WHOOP reports these per sleep (from its developer documentation): time in bed, awake, light, deep (slow-wave) and REM time, no-data time, sleep cycle count, disturbance count, sleep needed split into baseline, debt, strain and nap, respiratory rate, performance %, consistency %, efficiency %, and a nap flag. Its articles add latency and restorative sleep (deep + REM, typically 40–50% of sleep). Its Health Monitor adds overnight resting HR, HRV, blood oxygen and skin temperature against a personal baseline.

### 4a. Sleep detection with motion

Replace the HR-only detector in `Tracker/Health/SleepEngine.swift` with one that uses heart rate, motion and contact per minute.

- **Asleep minute:** on the wrist (`contact ≥ 0.8`), motion below a still threshold, and heart rate below the daytime baseline by the existing drop rule. When motion is nil (old data), fall back to the existing HR-only rule.
- **Still threshold:** start at the 30th percentile of the user's own waking-hours motion; store it as a constant candidate in `HealthConstants` and tune against the user's corrected sleep windows.
- **Sleep period:** asleep minutes merged across awake gaps under 60 minutes, as today.
- **Main sleep:** the longest period ending in the 24 hours up to 14:00 local on the day. Minimum 2 hours.
- **Off-wrist minutes** are "no data", never sleep or wake.

Add to `SleepSession` (all optional so stored sessions still decode): `latency`, `efficiency`, `disturbances`, `cycles`, `noData`, `restorativeShare`, `respiratoryRate`, `skinTempDeviation`, `oxygen`, `isNap`.

| Metric | Definition |
|---|---|
| Time in bed | first still, on-wrist minute of the period to final wake |
| Latency | time in bed start to first 10 continuous asleep minutes |
| Awake | awake minutes inside the period |
| Efficiency | asleep ÷ time in bed |
| Disturbances | awake bouts of ≥ 1 minute with motion above threshold |
| Stages | existing HR-based estimate, improved with motion (movement ⇒ light or wake) and RR variability (high, irregular ⇒ REM candidate; lowest HR, most regular, still ⇒ deep). Still labelled "estimated" |
| Cycles | number of deep → REM progressions |
| Restorative | (deep + REM) ÷ asleep |
| Performance | asleep ÷ need, capped at 100% |
| Consistency | existing 4-night timing measure |

### 4b. Naps

WHOOP flags naps, and a nap reduces that night's sleep need by its length. It does not publish its detection rule; users report short naps being missed. Our rule:

- A sleep period outside the main sleep, between 08:00 and 20:00 local, with **≥ 30 minutes asleep** and ≤ 3 hours.
- 30–60 minutes: saved as a pending nap with a "Was this a nap?" review card (reuse the detected-workout review pattern in `Tracker/UI/WorkoutViews.swift`). Over 60 minutes: saved as a nap directly.
- Tonight's need: `need = baseline + strain + debt − min(napAsleepToday, 90 min)`. Add `needNap` to `SleepSession` and to `SleepEngine.Need`.
- Naps never count as a calibration night and never produce a Recovery.
- Store naps in the existing `sleeps` storage with `isNap = true`; add a manual "Add nap" entry on the Sleep screen.

### 4c. Respiratory rate

Derive from beat-to-beat intervals during sleep (breathing modulates heart rhythm).
- Take 5-minute windows of still, asleep minutes with ≥ 200 valid intervals.
- Resample the RR series to 4 Hz, remove the mean, find the dominant frequency between 0.13 and 0.40 Hz (8–24 breaths/min).
- Night value = median of the window values; needs ≥ 12 windows, else nil.
- Pure function in `Tracker/Health/RespiratoryEngine.swift` with tests on synthetic RR series at 12 and 18 breaths/min (must return within ±1).
- Label "estimated from heart rhythm".

### 4d. Skin temperature

The record carries a raw ADC value, not degrees. Do not show a temperature.
- Night value = median `skin_raw` over still, on-wrist, asleep minutes.
- Show only **deviation from the user's own 14-night baseline**, as "Typical", "Above your usual" or "Below your usual" (beyond 2 standard deviations), once 7 nights exist.

### 4e. Blood oxygen (research gate)

The band does not send an oxygen percentage. It sends one raw red and one raw IR value per second. Whether a percentage can be derived from those is **unproven**. Do this as a gated spike:

1. Export one full night of `red`, `ir`, heart rate and motion from the phone database.
2. For still, on-wrist, asleep minutes compute the pulsatile part of each channel over 10 s windows (standard deviation ÷ mean) and the ratio R = (red pulsatile ÷ red mean) ÷ (IR pulsatile ÷ IR mean).
3. **Gate:** proceed only if (a) R is stable within a still minute (coefficient of variation under 15% for most minutes), and (b) the user can provide at least 20 paired readings from a fingertip oximeter taken while resting, so a curve `SpO2 = a − b·R` can be fitted with error under 3 points.
4. If the gate passes: show "Blood oxygen (experimental)" as a nightly median and lowest sustained value, with a note that it is not a medical measurement.
5. If the gate fails, or 1 Hz data cannot resolve the pulse (likely, since a pulse needs several samples per beat): do **not** show a percentage. Offer instead an "oxygen signal vs your baseline" indicator from nightly median `red_ir`, with the same typical/above/below wording as skin temperature, and say plainly in the report that a true percentage is not available from stored data.

Do not send any command to enable a raw optical stream overnight to get around this without asking the user first: it would cost band battery and breaks the Phase 1 rule.

### 4f. Sleep screen

Update `Tracker/UI/SleepView.swift`:
- header: hours asleep vs needed, performance ring;
- stage bar with awake / light / deep / REM durations and the "estimated" note;
- tiles: efficiency, consistency, latency, disturbances, restorative %, cycles;
- "Sleep needed" breakdown: baseline, strain, debt, naps (negative);
- "Overnight" card: resting HR, HRV, respiratory rate, skin temperature state, oxygen (per 4e); each with its baseline comparison once calibrated, or "Calibrating" before;
- naps list for the day, with the pending-nap review card;
- each tile shows "Not enough data" rather than a zero.

**Check:**
- CLI tests on synthetic nights:
  - a clean 8-hour night gives onset and wake within ±5 min, and efficiency and latency as constructed;
  - an off-wrist hour inside the night is no-data, not wake;
  - a 45-minute afternoon nap is pending, and a 90-minute nap is saved and reduces need by 90 minutes;
  - a 20-minute doze is ignored;
  - still TV-watching with a normal heart rate is not sleep.
- Simulator with `-demoHistory` extended to include motion, contact and one nap.
- On the phone: compare three nights against the user's own account of bedtime and wake time; onset and wake within 15 minutes.

## Phase 5: Calibration, recovery, strain and zones

Rules (rationale and sources in `docs/calibration-review.md`):

| Rule | Value |
|---|---|
| Valid night | main sleep with ≥ 4 h asleep and ≥ 80% of minutes measured |
| Night resting HR | lowest 5-minute average while asleep (one definition everywhere; remove the whole-night median in `Personalization`) |
| Night HRV | median of 5-minute RMSSD windows over still, asleep time; needs ≥ 6 windows |
| Recovery appears | after 4 valid nights; "Early" until 14 |
| Baseline window | rolling 28 nights; lapses after 14 days with no valid night |
| Missed nights | pause progress, never reset |
| Strain | shown from day 1; "Provisional" until resting HR is measured |
| Zones | heart-rate reserve at 40 / 60 / 70 / 80 / 90% (WHOOP's published method) |
| Resting HR for zones | median of the last 14 valid nights; 70 bpm until 4 nights exist |
| Zone drift | each boundary moves at most 2 bpm per week |
| Max HR | 208 − 0.7 × age; raised to an observed value held ≥ 2 minutes in a workout with on-wrist contact; never lowered automatically; manual override wins |

Steps:
1. `Tracker/Health/HealthConstants.swift`: `recoveryMinimumNights = 4`; add `recoveryEarlyNights = 14`, `baselineLapseDays = 14`, zone percentages, drift limit.
2. `Tracker/Health/Calibration.swift`:
   - one `CalibrationPhase` enum: `.setup`, `.calibrating(validNights: Int)`, `.early(validNights: Int)`, `.calibrated`, computed from the count of valid nights in the window plus `SetupState`;
   - `established` becomes a computed value (count in window ≥ threshold and not lapsed), not a sticky flag;
   - last night counts as soon as its sleep is detected (include today's wake-day in the window);
   - remove the "load" baseline gate on Strain;
   - each night records *why* it did not count: too short, gaps, band off, excluded, no sync.
3. `Tracker/Health/Zones.swift` and `ZoneConfiguration.zone`: reserve-based boundaries from the table; delete the percent-of-max path except as the manual option. `Tracker/UI/HRMath.swift` (`ZoneConfig`) must read the same configuration so the UI and engines agree.
4. `Tracker/Health/RecoveryEngine.swift`:
   - with HRV history: `0.60 × HRV z + 0.25 × (−resting HR z) + 0.15 × sleep performance z` (WHOOP says HRV carries most of the signal; these exact weights are our choice);
   - without HRV: keep the existing fallback and mark the result "without HRV";
   - if respiratory rate is more than 2 standard deviations above baseline and the score is under 50, subtract up to 10 points (WHOOP applies respiratory rate only to already-low scores);
   - keep the centre at 58 and the 34 / 67 bands.
5. Strain history: stop freezing a "not ready" baseline per day. Store the zone configuration used for each day; days first computed with provisional zones are recomputed once when resting HR is first measured, then frozen.
6. Remove the duplicate activity detector in `CalibrationEngine.activities`; "Unconfirmed activity" uses `ActivityDetector` results.

**Check:** CLI tests:
- no Recovery after 3 valid nights, and "Early" Recovery after 4;
- a missed night pauses the count;
- the baseline lapses after 14 empty days and recovers when nights return;
- a zone boundary moves ≤ 2 bpm per week when resting HR drops by 10;
- Strain is non-nil on day 1 with a profile;
- Recovery with identical inputs but a high respiratory rate is lower only when the base score is under 50.

## Phase 6: Calibration UI

One model (`CalibrationPhase`) drives every screen.

| Phase | Home | Recovery ring | Strain | Sleep |
|---|---|---|---|---|
| Setup | Setup checklist (Phase 3) | hidden | hidden | hidden |
| Calibrating (0–3 nights) | Card "Getting to know you · Night 2 of 4", 4-step bar, and "Last night counted" or "Last night didn't count: band was off for 3 h" | grey dashed ring, "Calibrating · 2 of 4" | shown, "Provisional" tag | shown from the first valid night |
| Early (4–13) | Small card "Personal baseline · 9 of 14 nights" | coloured, "Early" tag | shown | shown |
| Calibrated | no card | normal | normal | normal |

1. `Tracker/UI/CalibrationCard.swift`: the Home card for the Calibrating and Early phases. Tapping opens the Calibration screen.
2. `Tracker/UI/Components.swift` `RingView`: add a `calibrating` style (dashed grey track, no fill).
3. Rebuild `Tracker/UI/CalibrationView.swift` with the app's cards instead of a system `Form`:
   - phase header with progress;
   - **night strip:** last 14 nights as dots, filled when valid; tapping a hollow dot shows the reason;
   - baselines: resting HR, HRV, respiratory rate, skin temperature, each with value, nights counted and state;
   - zones with their bpm ranges and "updates gradually, at most 2 bpm a week";
   - keep weight history, excluded days, sleep correction and export, with separate date pickers for weight and excluded day;
   - "Confirm" on an unconfirmed activity asks for the activity type instead of always saving Walking.
4. Wording: "Calibrating" only in the first 4 nights; "Early" and "Provisional" after. Every not-ready metric has one plain line saying what is needed.
5. A local notification when Recovery first becomes available, respecting the existing notification settings.

**Check:** simulator screenshots for each phase using `-demoHistory` with a new `-demoNights N` flag (0, 2, 5, 20), in light of the bottom-spacing rule; scroll each screen to its end.

## Phase 7: End-to-end verification and docs

1. Run the CLI checks, the simulator build and the device build.
2. Simulator pass through every screen in each calibration phase.
3. On the phone, with the user: fresh baseline, wear four nights, confirm Recovery appears on the fifth morning, and compare sleep times with their own account.
4. Pull `ble-log.txt` after 48 hours and report the Phase 1 measures.
5. Energy: one day of normal use; report the app's share from iOS battery settings and the band's battery drop per day. Target: under 3% of phone battery per day with no live screen open.
6. Update `README.md` (transport, record fields, sleep metrics, calibration phases, what is estimated) and add the two review documents to its references.

## Out of scope

- A laptop collector or handoff (see the decision gate in the reliability review).
- HealthKit, backups, firmware updates, alarms and haptics.
- Any claim of medical accuracy.

## What to tell the user at the end

For each phase: done or not, the measured results against its check, and anything that could only be verified by wearing the band. State clearly whether blood oxygen passed its gate.
