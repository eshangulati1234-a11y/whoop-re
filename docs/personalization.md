# Personalization v2

Calibration lives in `Tracker/Health/Calibration.swift`; application integration uses the serial utility worker in `Personalization`. Open **Device → Calibration** (also linked from Home) to inspect progress, log dated weight, exclude illness days, review sustained activity, enter effort/strength notes, correct sleep windows and export data.

Seven completed days with 75% coverage and no gap above 180 minutes qualify daily load. Resting HR independently needs seven nights with 240 measured minutes and 80% coverage. HRV needs seven qualifying nights containing 30 windows with at least 20 valid contiguous RR intervals. These are engineering thresholds, not validated physiological criteria. Proprietary WHOOP frames currently supply no decoded RR intervals, so HRV may remain unavailable. Legacy RR aggregates without continuity metadata cannot qualify.

Learned resting HR adapts at most 1 BPM per new qualifying observation using a trailing 28-day median. Missing observations retain the baseline and expose staleness after seven days. Manual resting HR takes precedence. A 3-BPM target shift sustained across three new observations produces at most one notice per week; it is not interpreted as fitness improvement. Maximum HR remains age-estimated or manually supplied.

Zone boundaries after calibration are 50/60/70/80/90% HR reserve. Strain remains an experimental Edwards-style weighted-minute load mapped through `21*(1-exp(-load/200))`; the old percentage-max engine remains available for diagnostic comparison. Initial strain requires both daily-load and resting calibration. Personal context compares matching elapsed-day load against seven qualifying prior observations and is unavailable for very quiet baselines.

Activity calories use ten consecutive measured zone-1-or-higher minutes to identify unconfirmed activity, ending after five low minutes or two missing minutes. Only measured elevated minutes contribute. Sleep, dismissed activity, pauses and unsupported workouts are excluded; confirmed aerobic workouts and automatic periods never double count. Stress/heat cannot be distinguished from exercise using HR alone. Keytel-derived active calories remain experimental, and daily totals omit unmeasured activity. Weight entries are effective-dated. Strength calories are unavailable.

Schema v4 adds health documents, append-only metric revisions and RR continuity counts. Migration is transactional; existing history and workouts are retained. Daily/workout baseline configurations and profiles are frozen; changed inputs produce separate exported revisions. Sleep correction is a user-supplied sleep window, not validated sleep staging. Normal sleep summaries omit stage hypotheses.

The calibration worker owns its SQLite connection. It runs after sync, foreground refresh or feedback; no Bluetooth streaming or polling is added for calibration. Existing live UI throttling remains. Battery effects still require device measurements.

## Validation

Run the Swift command from README and `python3 -B scripts/test_evaluate_health.py`. The suite covers calibration thresholds, gaps, independent gates, repeated adaptation, weights, overlapping workouts, pauses, DST lengths, RR preservation, migrations and result revisions.

ShareLink exports JSON with 28 days of HR/live-minute data, baseline, feedback, activity candidates and saved result revisions. Times use ISO 8601 in the outer export; SQLite revision payloads use Unix seconds. References must be obtained independently. `python3 scripts/evaluate_health.py predictions.csv references.csv` compares held-out rows with columns `kind,id,value,start,end`: `hr`/`energy` use value in BPM/kcal, `sleep`/`workout` use Unix-second start/end. IDs must identify independently matched observations. Reports include missing/unmatched counts, mean absolute error and bias. No reference means no accuracy result. The harness never fits coefficients.

Device acceptance remains: sync and reopen with historical data; confirm calibration persists; test corrections and weights; inspect Live Activity gates; compare matched foreground/background energy sessions. No accuracy or battery superiority is claimed from simulator tests.
