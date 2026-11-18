# Steps and blood oxygen from the band: research notes (10 Nov 2026)

Data: the phone's stored raw frames, 10 Nov 12:41–19:28 (25,283 v24 records, 760 v25 records). Daytime only; no night yet.
Scripts: kept in the session scratchpad, not the repo.

## Steps: likely a counter in every v24 record

The u16 at inner offset 88 of the 96-byte v24 record behaves like a cumulative step counter:

| Check | Result |
|---|---|
| Direction | Rose 2,050 times, fell twice, flat otherwise |
| Range | 0 → 3,419 over 6.8 h |
| Falls | Both reset to 0, at 13:43 and 14:59, each right after a gap in records (band restart or resync) |
| Per-second increments | Mostly 1–3 (about 2 steps/s when walking); 141 jumps of 11–13 (likely batched) |
| Busiest minute | 106 |
| Minutes with ≥ 40 counts | Median 59/min, band motion 394 mg vs 65 mg in minutes with no counts |
| Flat stretches | 17:55–18:44 flat at 284 while HR was 58–60 (sitting) |

OpenStrap's protocol notes call byte 88 a u8 "resting/baseline HR held value". Our data contradicts that: read as u16 the value climbs into the thousands, and the low byte alone wraps through all 256 values.

**Not proven.** There is no ground truth yet. The app now records iPhone steps, so the check is: compare hourly band-counter increments with iPhone pedometer steps for 2–3 days (hours with the phone in a pocket). Adopt the band counter if it is within about 10%, summing increments across resets.

## Blood oxygen: not decodable from what we have

- **Per-second values (v24):** offsets 64 (red), 66 (IR), 70 (ambient) and 72 (LED drive) are slow raw light levels. OpenStrap reads them the same way. They carry no pulse, so the red/IR "ratio of ratios" behind SpO2 can't be computed from them.
- **v25 bursts (76 bytes):**
  - **What they hold:** 24 signed int16 values per second, one smooth channel, 40-second bursts every 19 min 52 s.
  - **Heart-rate match:** when the wrist was still, the waveform's dominant rate matched the band's heart rate within 4 BPM in 7 of 8 bursts. When moving, it did not.
  - **What that suggests:** a single optical pulse waveform, probably green.
  - **Status:** no public project documents this record.
- **Missing channel:** SpO2 needs pulse waveforms from both red and infrared. Only one channel appears, and only in daytime.
- **Where WHOOP does it:** WHOOP measures SpO2 during sleep. OpenStrap says the % is computed in WHOOP's cloud, not on the band.

**Next:**
1. Pull the frames after a full night and check whether night bursts carry two channels or change type.
2. If red and IR waveforms exist, build a ratio-of-ratios estimate.
3. Show it only after checking it against a finger pulse oximeter over several nights.

Without both, the tile stays "No reading".

## Sources
- [OpenStrap/research PROTOCOL.md](https://github.com/OpenStrap/research/blob/main/PROTOCOL.md): v24 field table
- [OpenStrap/protocol](https://github.com/OpenStrap/protocol)
- [johnmiddleton12/wearable FINDINGS.md](https://github.com/johnmiddleton12/wearable/blob/main/FINDINGS.md)
- [AStrasler/whoop4-ble](https://github.com/AStrasler/whoop4-ble)
- [WHOOP: blood oxygen monitoring](https://ww2.whoop.com/thelocker/metric-blood-oxygen-monitoring/)
- [Wearable Technologies: WHOOP 4.0 sensors](https://wearable-technologies.com/news/the-new-whoop-4-0-comes-with-pulse-oximeter-and-skin-temperature-sensor)
