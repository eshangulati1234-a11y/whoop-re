# Bluetooth reliability review

10 Nov 2026. Analysis only: no code was changed for this review.

**Update, evening of 10 Nov:** the phone's own database refuted hypothesis 1 below. Syncs do not stall in the preflight; the band answers every preflight command, streams about 50 records per chunk, and then goes quiet after an END marker while data is still waiting. See "Evidence from the 10 Nov device log" in `docs/implementation-plan.md`, which supersedes the Phase 1 reasoning here.

Evidence labels used below:
- **Code** = read in this repo today.
- **Device log** = `ble-log.txt` pulled from the iPhone today (6 lines, one sync).
- **noop** = ryanbr/noop protocol docs (firmware MAXIM 41.17.6.0 / NORDIC 17.2.2.0).
- **whoop4-ble** = andyguzmaneth/whoop4-ble (one person's band, firmware not stated).
- **Apple** = TN3115, updated 15 Sep 2025.
- **WHOOP** = "WHOOP Troubleshooting 101", dated 13 Aug 2026.
- **Inference** = my reasoning, not observed.

## 1. Recommendation

**Stay phone-only (A) and simplify the transport before building anything distributed.** Confidence: medium-high that the transport is the problem; low on how much each defect contributes, because the phone has logged only one sync so far.

The app does more on the radio than either community client does, and several of the extras are plausible causes of the stalls:

1. **Sync waits on four commands before it asks for history** (hello, name, range, alarm). Any one missing reply ends the sync. Neither reference needs them: noop says command 22 needs no preflight and hello "is not strictly required"; whoop4-ble's band did not answer commands at all until 22 had been sent.
2. **Live HR turns on the raw sensor stream.** Our `rawRealtime` is command 63, which noop identifies as the switch for the type-43 stream: about 1.9 KB per second of motion or optical samples. Heart rate does not need it. The standard heart-rate characteristic (2A37) gives HR and RR at about 1 Hz on both references.
3. **Two commands are sent whose meaning on WHOOP 4 is not what the code assumes.** `optical` (107) is "read IMU stream state" on 41.17.6.0 per noop, not an optical switch. `alarm` (67) is "get alarm time", unrelated to sync.
4. **The app cancels its own connection attempts.** A connect that takes over 20 s is cancelled and retried on an app timer. The timer does not run while iOS has the app suspended, so nothing is pending and iOS has no reason to wake the app when the band comes back.
5. **`linkValid` is sent every 10 s while the app is open.** noop does not send it at all, and observed that extra commands in the middle of an offload stopped the history stream. (It is no longer sent during a sync as of today's build.)

Unresolved dependencies:
- The band's firmware version is not recorded by the app, so which reference applies is unknown.
- Today's fixes (no disconnect on stall, backoff) have one successful sync as evidence and no stall yet.
- Whether GET_CLOCK answers outside a history transfer on this band is unknown.

## 2. Fact check

| Claim | Verdict | Evidence | Scope | Still uncertain |
|---|---|---|---|---|
| Dual-core Nordic chip, one core for Bluetooth, one for sensors | **Wrong as stated.** Two separate processors, not a dual-core part | noop: Nordic nRF52840 runs Bluetooth; a separate application processor with its own "MAXIM" firmware image does the rest. The nRF52840 is a single-core chip | 41.17.6.0 / 17.2.2.0 | Exact application processor part |
| About 8.6 million HR data points a day | **Unverified; describes raw sampling, not stored or transmitted data** | 100 samples/s × 86,400 s = 8.64 M, and noop saw about 100 samples per axis per second in the raw stream. Stored history is about one record per second (whoop4-ble: ~86,000 records/day; our records are 96 bytes) | Raw rate: noop captures | I did not find a WHOOP primary source for the number |
| Keeps 3–7 days offline | **Contradicted by one observation; no official figure found** | whoop4-ble pulled 8+ full days in one transfer and estimates ~14. The WHOOP page read today gives no number | One band | Depends on record layout and flash size; official figure not confirmed |
| App requests data from the last saved timestamp | **Not how the observed protocol works** | The band keeps the cursor. The client sends command 22, the band streams from its own trim point, and each chunk ends with a cursor the client echoes back (noop, whoop4-ble, **Code**) | Both references | What the official app does beyond this |
| Band deletes data only after the cloud confirms upload | **Unverified** | Observed: the band advances its trim when the *client* acknowledges over Bluetooth. Whether WHOOP's app waits for its cloud before acknowledging is unknown. WHOOP lists "not having any cell service" as a cause of "data catching up", which is a hint, not proof | — | Official app's ACK timing |
| iOS is forced to relaunch the WHOOP app after a force-quit | **False before iOS 26. From iOS 26, true only for apps that set the accessory up with AccessorySetupKit** | Apple TN3115: "App Force Quit by the user: No", with the iOS 26 note. WHOOP itself lists force-closing the app as a cause of disconnects | iOS 26+ | Whether WHOOP uses AccessorySetupKit |
| Band sends only raw optical data; HRV, sleep, strain all run in AWS | **Partly false** | The band computes heart rate and RR intervals itself: they are in 2A37, in type-40 packets and in every history record. Scores being cloud-side is asserted by whoop4-ble, not demonstrated | Both references | Where each score is computed |
| Cloud processing is why the official app avoids crashes and battery drain | **Unsupported** | No source. Our local maths runs on about 86,000 one-byte heart rates a day, which is small next to radio time (**Inference**) | — | Needs profiling, see stage 4 |

## 3. What is probably failing

| # | Hypothesis | Why I rank it here | What would tell them apart |
|---|---|---|---|
| 1 | **Sync stalls in the preflight**, before history is requested | **Code**: four strictly-matched replies gate the transfer. whoop4-ble's band ignores commands before 22. The old sequence-matching bug would have failed here every time | The stall line in the connection log names the step. A stall at hello/name/range/alarm confirms it; a stall at history refutes it |
| 2 | **The app drops and re-makes the link itself** | **Device log**, first line: "Connection setup timed out" then connected 3 s later. Before today, every sync timeout also disconnected and re-synced at once | Count disconnects that have a CoreBluetooth error (real) against ones the app started (logged as "Reconnecting: …") |
| 3 | **Extra commands interfere with the transfer** | noop: re-sending handshake commands mid-offload stopped type-47 records. We sent `linkValid` every 10 s during sync until today | Bytes of type-47 per second before and after any command sent mid-transfer |
| 4 | **The raw stream competes with history** | **Code** turns on ~1.9 KB/s for live HR and relies on a stop command being honoured as sync starts. noop stops this stream on every connect, which suggests it can be on by default | Log bytes per second by packet type during a sync; type 43 should be zero |
| 5 | **"No signal" is often not a link failure** | **Code**: 2A37 is unsubscribed off the live screens, live is paused during sync, and anything older than 10 s is "stale". The band also stops reporting HR off the wrist | Log 2A37 subscribe state, time of last reading and wrist on/off events next to each "No signal" |
| 6 | **iOS suspension** | App timers (reconnect, watchdogs) stop when suspended; background sync has a 20 s budget | Log app state changes; compare failures in foreground against background |
| 7 | **Clock check delays or blocks the first sync** | whoop4-ble: GET_CLOCK answers only during a transfer. **Device log** shows 110 s between connect and the first sync with nothing logged in between | Log the clock check outcome and the moment the link becomes ready |
| 8 | **Decoder, CRC or cursor errors** | Lower: 155 records decoded and were acknowledged today; our cursor offsets match noop's | Rejected-record count; the same chunk arriving twice after an ACK |
| 9 | **Main-thread database work** | Lowest: a chunk is one transaction, but it runs on the main thread inside the Bluetooth callback with unprepared SQL (**Code**) | Time each `persist` call; anything over 100 ms matters |

## 4. How the band synchronises (what is known)

- **Observed on both references and in our code:** send command 22; the band streams type-47 records; each chunk ends with a type-49 END carrying an 8-byte block; the client stores the chunk, then sends command 23 with that block; a COMPLETE marker ends the session.
- **Trim:** acknowledging advances the band's trim cursor. whoop4-ble reports that an unacknowledged chunk is replayed. noop lists replay after a disconnect, chunk size and wrap behaviour as **open questions** on 41.17.6.0.
- **Official app:** noop says its 15-minute backfill timer "matches WHOOP", and whoop4-ble says the official app sets the clock on every connect. Both are community statements about the official app, not captures I could check.
- **Unknown:** whether the 8-byte block is honoured exactly after a reconnect; behaviour when two clients alternate.

## 5. What iOS can and cannot guarantee (Apple TN3115)

| State | Does iOS bring the app back for a Bluetooth event? |
|---|---|
| Foreground | App is running |
| Background, suspended in memory | Woken without relaunch |
| Removed from memory by the system, or crashed | Yes |
| Force-quit by the user | No. From iOS 26, yes only if set up through AccessorySetupKit |
| Bluetooth switched off in Settings | No |
| Control Center Bluetooth button | From iOS 26, only with AccessorySetupKit |
| Phone restarted | Yes, after the first unlock |

Apple's condition for all of these: the app must be **waiting on a specific Bluetooth event** (a pending connect, a subscribed characteristic). An app with only a timer running is waiting on nothing. Wake-ups give seconds of run time, not a schedule, so background sync must be short and resumable. Continuous background streaming is not something to design around.

## 6. Would moving calculations off the phone save energy?

Probably not much (**Inference**, needs the stage 4 measurement). Likely order of cost, highest first:
1. Raw streaming at ~1.9 KB/s while a live screen is open.
2. Reconnect and resync loops.
3. Long history transfers after days away.
4. Wi-Fi or cellular upload to a laptop, which is a new cost that offloading would add.
5. Screen updates once a second.
6. Database commits.
7. Local calculations on roughly 86,000 samples a day.

Offloading removes item 7 and adds item 4.

## 7. Smallest reliable live stream

Subscribe to 2A37 and send nothing else. Both references treat it as sufficient for live HR and RR. Tests, each on its own connection:
1. 2A37 only for 10 minutes on the wrist. Pass: a reading at least every 3 s.
2. Add command 3 (`realtimeHR`). If readings are no more frequent or complete than test 1, drop it.
3. Send 63 = off once after connect and confirm no type-43 packets arrive.
4. Run a history sync with 2A37 left subscribed. If the sync is no slower than with it off, live HR never needs to pause for a sync.

## 8. Data-safety rules

Already in place (**Code**): store before acknowledging; raw frames kept even when a record can't be decoded; duplicate inserts ignored; the 8-byte cursor echoed unmodified; an unfinished chunk is dropped unacknowledged.

Missing:
- **Session identity.** A reply or END marker that arrives after a reconnect could be taken for the current session. Tag every request and chunk with a per-connection number.
- **Sequence wrap.** The 8-bit sequence repeats after 256 commands; `linkValid` every 10 s reaches that in about 43 minutes. Fewer commands is the simplest cure.
- **Cursor history.** Save each acknowledged cursor with its time, so a repeated or backwards cursor is visible.
- **Unknown layouts.** noop documents an 84-byte v25 record as well as our 96-byte v24. Count and surface records we store but cannot read.
- **Disk failure.** A failed write must stop the sync without acknowledging (it does) and say so plainly.

## 9. What the laptop changes

Little, for reliability. The band is often out of the laptop's Bluetooth range, a closed laptop sleeps, and once any collector acknowledges a chunk the band discards it. WHOOP's own guidance is "strongly advise against syncing WHOOP to several devices". A laptop is useful as a **backup and analysis copy** fed by the phone, which needs only an authenticated, encrypted upload on the home network and can fail without losing anything.

## 10. Architectures

| | A. Phone only | B. Phone collects, laptop analyses | C. Laptop collects | D. Handoff between both |
|---|---|---|---|---|
| Reliability | Good once the transport is simplified | Same as A for collection | Worse: band is often out of range | Worst: two owners of a destructive cursor |
| Phone battery | Lowest once raw stream is gone | A plus upload cost | Low, but data arrives late | Unclear |
| Away from home | Works | Works; laptop catches up later | Band buffers; days of delay possible | Works, with handoff risk |
| After a force-quit | Stops until reopened (unless AccessorySetupKit) | Same | Unaffected | Laptop can take over |
| Data-loss risk | Low | Lowest (second copy) | Laptop disk is the only copy until the phone pulls | Highest |
| Complexity | Lowest | Moderate | High | Very high |

**Choose A now. Add B later for backup if wanted. Do not build C or D** unless the gate in section 13 is met.

## 11. Experiment plan

Targets are provisional engineering goals, not platform guarantees. All counts come from the connection log.

| Stage | Change | Measure | Pass |
|---|---|---|---|
| 0. Instrument | Log firmware version, link-ready time, clock outcome, each command and its reply time, bytes/s by packet type, disconnect error codes, app state | — | Every sync and every drop can be explained from the log alone |
| 1. Baseline | Today's build, 48 h of normal wear | Sync success rate; app-started disconnects; step named in each stall | Recorded, no target |
| 2. Minimal sync | Once per connection: 63 = off, set clock. Sync = command 22 only, clock read inside the transfer. No `linkValid`, no command 67 or 107 | Same as stage 1 | ≥ 95% of syncs complete over 48 h; zero app-started disconnects while the band is in range |
| 3. Minimal live | 2A37 only (tests in section 7) | Gap between readings on the wrist | No gap over 5 s in 30 min; sync time unchanged with 2A37 on |
| 4. Connection | Leave `connect` pending with no timeout; watchdog only the discovery step | Time to reconnect after 30 min out of range with the app in the background | Reconnects and syncs without opening the app, 9 of 10 tries |
| 5. Energy | Xcode energy gauge and iOS battery share, one day per configuration | Battery share of the app; band battery per day | Live screen closed: under 3% of phone battery per day |

## 12. Who owns what

```
WHOOP band ── stores ~1 record/s, keeps the trim cursor
     │  one Bluetooth owner at a time
     ▼
iPhone ── the only collector
     │    1. receive chunk  2. commit to SQLite  3. acknowledge cursor
     │    live HR from 2A37 only, while a live screen is open
     ▼
Phone database ── source of truth; all scores computed here
     ┆  optional later (B): encrypted copy over home Wi-Fi
     ▼
Laptop ── backup and heavy re-analysis; never talks to the band
```

## 13. Decision gate

Adopt **B** only when stages 2–4 pass and there is a concrete need the phone can't meet (a backup, or an analysis too slow on the phone as measured in stage 5).

Consider **C or D** only if, after stages 2–4, the phone still fails more than 1 sync in 10 with the band in range **and** a test shows the band replays unacknowledged chunks byte-for-byte after a reconnect. Without that second result, a handoff cannot be made safe.
