# Battery-aware automatic history synchronization

Status: planned; automatic sync is not yet enabled. Implement after functionality phases 0–1 and moving SQLite work off the UI executor.

## Policy

- Keep live HR off while backgrounded unless an explicitly active workout owns it. Never enable live streaming merely to obtain a background execution opportunity.
- On foreground, load cached data immediately, display its measurement timestamp and a separate last-successful-sync timestamp. Refresh history once the connection is ready if last successful sync is over 60 seconds old. Coalesce repeated foreground/connection triggers into one transfer.
- On a legitimate BLE reconnect, band backlog prompt, or granted BGAppRefresh opportunity, request history only when the last successful transfer is at least 30 minutes old. This is a minimum interval, not a guaranteed schedule.
- Do not use a repeating background timer or repeated scans to keep the app alive. Maintain the known peripheral through Core Bluetooth restoration. Stop discovery after a bounded window, with exponential retry backoff.
- Low Power Mode / serious thermal pressure: defer nonessential background transfers; manual foreground sync remains available. Surface the reason rather than claiming the data is current.
- Bound background transfers by the earlier of system expiration or a 20-second app budget; stop with the existing abort command and retain already committed batches. Resume later from the device cursor. Never ACK an uncommitted batch.
- Prefer brief connected idle over repeated reconnects only if physical-device energy measurements support it. Do not assume either is cheaper.
- Serial command coordinator must prevent sync, stream changes and clock repair from overwriting one another's expected responses. Each operation uses a session generation token. Stale callbacks and database completions cannot ACK a new session.

## Implementation

Create a pure SyncPolicy (clock injected), a SyncCoordinator and a dedicated serial database worker. Register a BGAppRefresh task at launch, add only required background capabilities and reschedule opportunistically; no exact execution promise. Flush accumulated live minutes on background/finish. Handle background expiration with cancellation and task completion exactly once. Restore pending BLE state, not arbitrary first peripherals. Keep bounded diagnostics for sync cause, bytes, duration, outcomes and latest measurement time.

UI freshness: cached readings remain visible while refreshing; show Updating, Last recorded, connection state or failure. No fabricated interpolation. Older historical rows and fresh live readings retain distinct sources.

## Tests and device validation

Fake-clock tests: coalescing, fresh cache, stale cache, retry backoff, low power/thermal deferral, expiration, midnight, failed commit, disconnect during commit and duplicate batch replay. Confirm foreground refresh does not repeatedly restart active transfers. Confirm app-inactive-without-workout sends stream-off commands and stops live heartbeat. Test force quit separately: background relaunch cannot be promised after user force quit.

Measure 24-hour phone/band discharge and sample coverage against manual-sync baseline and a live-only workout baseline. Compare foreground launch latency, database time, BLE bytes and wakeups. Set battery regression thresholds from those measured baselines, not an invented percentage. Test a long backlog without blocking scrolling or draining it in one unbounded background session.

References: https://developer.apple.com/documentation/technotes/tn3115-bluetooth-state-restoration-app-relaunch-rules and https://developer.apple.com/documentation/backgroundtasks/bgapprefreshtaskrequest

## Functionality-plan corrections to resolve before relevant phases

The supplied Keytel male formula produces about 11.34 kcal/min (680 gross kcal/hour) for age 30, 75 kg and HR 150; active calories subtract resting energy, so tests must specify gross vs active. Per-minute overlap must deduplicate observations rather than weight sources repeatedly. HR-only sleep stages cannot be presented as verified REM/deep; prefer sleep-window estimates and clearly separate experimental hypotheses. Confirm whether the newer document intentionally replaces the previously agreed 7/28-night calibration with its 4/14-night policy before recovery implementation.
