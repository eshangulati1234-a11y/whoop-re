# Calibration: how WHOOP does it, and what we should change

10 Nov 2026. Research and design only; no code was changed.

Source labels: **WHOOP** = an official whoop.com page; **Community** = WHOOP forum replies with no staff badge; **Code** = this repo.

## 1. What WHOOP does

| Topic | What WHOOP does | Source |
|---|---|---|
| First Recovery | Greyed out for the **first 4 days** while WHOOP estimates your normal range and your higher-capacity state | WHOOP, Podcast 40 page (updated May 2026) |
| Recovery inputs | Overnight HRV, overnight resting HR and Sleep Performance. HRV carries most of the signal; the other two add context mainly when they diverge from HRV. Respiratory rate added later, and only adjusts already-low scores | WHOOP, Podcast 40 and the respiratory-rate update article |
| Recovery centre | Scores are built so that most people average around 58–60% | WHOOP |
| Full baseline | About **30 days** of consistent wear | Community (not confirmed by WHOOP) |
| Tonight's Sleep / Sleep Need | Hidden for the first "couple of nights", then appears once enough data exists; sleep need settles over the first month | Community |
| Healthspan | Needs 21 recoveries or sleeps in the first month; fully calibrated at 90 days | Community |
| Zones | **Heart rate reserve** (resting to max). Zone 1 starts at 40% of reserve, then 60/70/80/90% | WHOOP, HR zones article (Jul 2026) |
| Max HR | Starts as an age-based estimate; refined from observed workouts, with quality checks before it moves | WHOOP |
| Resting HR in zones | Zones are updated **monthly** as resting HR changes | WHOOP |
| Data before calibration | Heart rate is collected from the start; Sleep, Strain and Recovery fill in once there is enough continuous data | Community |

Not found in any source: what counts as a valid night, whether a missed night pauses or resets calibration, how HRV is windowed within the night, or how Strain behaves on day 1. The design below makes its own choices for these and says so.

## 2. How our calibration compares (Code)

| | WHOOP | Ours today | Effect |
|---|---|---|---|
| Recovery appears | After 4 nights | After **7** nights (`recoveryMinimumNights = 7`) | Almost twice as long to first score |
| HRV in Recovery | Main input | Only from **live** RR. History records are decoded for HR only | Recovery falls back to 70% resting HR + 30% sleep on most nights; HRV baseline stays 0/7 |
| Strain appears | (Not confirmed) | Hidden until **two** 7-day baselines are established; each "load" day needs 75% coverage and no 3-hour gap | No Strain for 8+ days; one missed charge or off-wrist afternoon slips it further |
| Zones | Reserve-based from 40%, updated monthly | % of max until resting HR is "ready", then reserve from **50%**. Switches in one step | Zone time and Strain jump on the day resting HR becomes ready |
| Resting HR | Overnight | Two definitions: median of the whole night (calibration), lowest 5 minutes (Recovery) | Values disagree; the median runs a few bpm high |
| Progress shown | Greyed score | Three separate x/7 counters on the Calibration screen, a separate "Calibrating" caption on Home, a Strain that is just missing | No single answer to "how much longer?" |
| Missed night | Unknown | Not counted, never says why | User can't tell if wear was the problem |
| "Ready" lapses | — | Never, once reached | Old resting HR keeps driving zones after weeks of no data |

## 3. Will the current window produce the right results?

Not yet, for three reasons:

1. **Recovery without HRV is mostly a resting-HR score.** WHOOP says HRV carries most of the signal. Our history records probably contain the beat-to-beat intervals: whoop4-ble's 93-byte layout puts an RR count and four RR values right after the heart-rate byte. We store every raw frame, so this can be checked against the phone's own data before trusting it. One check: compare RMSSD decoded from history with RMSSD from live 2A37 minutes recorded at the same times.
2. **Strain is gated on the wrong thing.** Strain needs max HR and resting HR, not 7 days of "load" history. Gating it on two baselines hides it for over a week and gains nothing.
3. **The zone switch changes the numbers overnight.** Day 7 Strain and day 8 Strain aren't comparable.

## 4. Proposed calibration rules

| Rule | Value | Why |
|---|---|---|
| A **valid night** | ≥ 4 h of sleep detected and ≥ 80% of it measured | Already our rule; keep it, but make it the only one |
| HRV for a night | RMSSD from RR intervals, valid when ≥ 30 one-minute windows have ≥ 20 intervals each | Keep the existing threshold, fed from history |
| Resting HR for a night | Lowest 5-minute average while asleep | Matches the Recovery definition; one number everywhere |
| Recovery appears | After **4 valid nights**, labelled "Early" until 14 | Matches WHOOP's 4 days |
| Baseline window | Rolling **28 nights**; a baseline lapses after 14 days with no valid night | Close to the community's ~30 days; lapse avoids stale baselines |
| Missed nights | **Pause**, never reset | Our choice; the sources don't say |
| Strain | From **day 1**. Before resting HR is known, use an estimated resting HR (70 bpm), labelled provisional | Shows Strain at once; no gate |
| Zones | Reserve-based, 40/60/70/80/90%, like WHOOP. Resting HR = median of the last 14 valid nights. Move each zone boundary at most 2 bpm per week | Matches WHOOP's method; avoids the overnight jump |
| Max HR | Start at 208 − 0.7 × age. Raise it when a workout holds above it for ≥ 2 minutes | Matches WHOOP's "refined from workouts" |
| Daily calories | From day 1 if a profile exists | Needs no baseline |

## 5. What the user sees

One calibration model drives every screen, in four phases:

| Phase | When | Home | Recovery ring | Strain | Sleep |
|---|---|---|---|---|---|
| **Setup** | No profile, band never synced, or clock not checked | Setup checklist: profile, band connected, clock checked, first sync | Hidden | Hidden | Hidden |
| **Calibrating** | Valid nights 0–3 | Card: "Getting to know you · Night 2 of 4" with a 4-step bar, and below it "Last night counted" or "Last night didn't count: 3 h off the wrist" | Grey dashed ring, "Calibrating · 2 of 4" | Shown, "Provisional" | Shown from the first valid night |
| **Early** | Valid nights 4–13 | Card shrinks to "Personal baseline · 9 of 14 nights" | Coloured, small "Early" tag | Shown | Shown |
| **Calibrated** | 14+ valid nights | No card | Normal | Normal | Normal |

Other screen changes:
- **Night history strip** on the Calibration screen: the last 14 nights as dots, filled when valid, hollow with the reason when not (too short, gaps, band off).
- **"What's needed" line** under each metric that isn't ready yet, in plain words.
- **Calibration screen restyled** to the app's cards (it's a plain system form today), keeping weight, excluded days and sleep corrections.
- **Wording:** "Calibrating" only for Recovery's first 4 nights; "Early" or "Provisional" after that.

## 6. How to check it works

- Unit tests with synthetic nights:
  - No Recovery after 3 valid nights; Recovery after 4.
  - A missed night pauses the count.
  - The baseline lapses after 14 empty days.
  - Zone boundaries move ≤ 2 bpm per week.
  - Strain is present on day 1.
- RR decode check on the phone's stored frames:
  - RR count 0–4.
  - Values 300–2000 ms.
  - Each record's HR ≈ 60000 / mean RR, within 10%.
  - History RMSSD within 15% of live RMSSD at the same minutes.
- Simulator with `-demoHistory` set to 0, 2, 5 and 20 days of history, with a screenshot of each phase.
- On the phone: wear for 4 nights from a reset baseline and confirm Recovery appears on the fifth morning.

## Sources

- WHOOP, [How WHOOP Recovery works (Podcast 40)](https://www.whoop.com/thelocker/podcast-40-whoop-recovery-maximize-readiness/)
- WHOOP, [Heart rate zones (HRR method)](https://www.whoop.com/us/en/thelocker/more-personalized-heart-rate-zones-with-whoop/)
- WHOOP, [How does WHOOP Recovery work](https://www.whoop.com/thelocker/how-does-whoop-recovery-work-101/) and [Adding respiratory rate to Recovery](https://www.whoop.com/fi/en/thelocker/adding-respiratory-rate-to-recovery/) (via search summaries)
- Community, [How long to learn baseline metrics](https://community.whoop.com/t/how-long-does-it-take-for-whoop-to-learn-your-baseline-metrics/359)
- Community, [Healthspan unlock](https://www.community.whoop.com/t/how-long-does-it-take-for-healthspan-to-calibrate-unlock/471)
- Community, [Tonight's Sleep not showing](https://www.community.whoop.com/t/sleep-planner-tonights-sleep-not-showing-up/11589)
- Community, [How WHOOP updates max HR](https://www.community.whoop.com/t/how-does-whoop-update-hf-max/1461)
- whoop4-ble, [protocol notes on the history record layout](https://github.com/andyguzmaneth/whoop4-ble)
