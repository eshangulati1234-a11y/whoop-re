# Estimation algorithms: review and improvement plan (10 Nov 2026)

Every number Pulse shows comes from one of the algorithms below. For each one: how it works today, what it does well, where it falls short (with evidence from your band data where I had it), and what the research suggests.

**Evidence available:** one afternoon of band history (10 Nov, 12:41–19:28, 408 minutes). No night has been recorded yet, so the sleep, HRV, resting heart rate and Recovery findings come from reading the code and the literature, not from measurement.

## Summary

| Algorithm | Code | Verdict | Biggest gap | Priority |
|---|---|---|---|---|
| Nap detection | `SleepEngine.naps` | **Wrong today** | Stillness test is relative to the nap window itself, so a restless window passes | 1 |
| Workout auto-detection | `ActivityDetector` | Works, fragile | Heart rate only; ignores motion and steps; two detectors disagree | 1 |
| Resting heart rate | `SleepEngine.build`, `CalibrationEngine.update` | Sound idea, no artefact guard | "Lowest 5 minutes" is set by any glitch | 1 |
| HRV | `HRTimeline.nightRMSSD` | Careful, but noisy | Whole-night median mixes sleep stages; two sources can mix | 2 |
| Sleep onset/wake | `SleepEngine.detectAll` | Reasonable | Heart rate lags sleep; lying awake still counts as sleep | 2 |
| Recovery | `RecoveryEngine.score` | Structure is right | Weights are guesses; raw RMSSD z-scores; outlier-sensitive baseline | 2 |
| Calories | `AdaptiveCalories`, `CalorieEngine` | Standard equations | Everyday movement below zone 1 adds 0 kcal | 2 |
| Strain | `CalibrationEngine.score` | Simple, stable | Step-shaped zones; age-formula max HR | 3 |
| Sleep stages | `SleepEngine.stages` | Unvalidated guess | Heart-rate level and wobble only | 3 (hide or rebuild) |
| Sleep need / performance | `SleepEngine.need` | Fine as a model | Generic constants | 4 |
| Skin temperature state | `SleepEngine.skinState` | Fine as relative | Raw sensor value, affected by fit and room | 4 |

---

## 1. Nap detection (priority 1: a real bug)

**How it works:** it reuses the sleep detector for 08:00–20:00 with shorter limits: 30–180 min, a 10-minute hold and a 20-minute merge gap. It then keeps a nap only if at most 10% of its minutes move more than `max(20 mg, 4 × the nap's own median movement)`.

**Good at:** naps that do show a clear heart-rate drop, while the wearer is still.

**Lacking:**
- **Today's false nap.** The stored nap for today runs 18:38–19:16. In that window your heart rate was 86–103 (median 92), and movement repeatedly reached 100–450 milli-g per minute. That's ordinary moving around, not sleep.
- **Why the stillness test passed:** it is measured against the window's own median. In a restless window the median is about 100 mg, so the limit becomes about 400 mg and almost every minute passes.
- **No daytime baseline.** With `daytimeBaseline: nil` the heart-rate drop is measured against the 80th percentile of the 08:00–20:00 window, which an evening dip can satisfy.

**Improve:**
1. Use an **absolute** stillness test: at least 80% of minutes under about 20–30 mg, and no run of 3 or more minutes over about 100 mg. The sleep literature's "sustained inactivity" means arm-angle change under 5° for 5 minutes or more (van Hees et al.). The gravity vector we already decode gives arm angle directly.
2. Require **no steps** from the band counter or the iPhone during the nap.
3. Measure the heart-rate drop against the **30–60 minutes before** the nap, not the whole day.

## 2. Workout auto-detection (priority 1)

**How it works:**
- A minute is "working" at 60% of age-predicted max HR (208 − 0.7 × age). For you that's about 115 BPM.
- A workout starts when 5 of the last 6 minutes are working. It ends after 5 measured minutes below the threshold, or 10 minutes without reaching it. It must last at least 10 minutes.
- The type is guessed from heart rate:
  - minute-to-minute swing of 8 or more → Strength
  - 70% of max or more → Running
  - under 65% → Walking
  - anything else → Other

**Good at:**
- Repeatable: re-running gives the same windows.
- Copes with data gaps.
- Never re-proposes a window you confirmed or dismissed.
- Steps aside when you started a workout yourself.

**Lacking:**
- **Heart rate alone can't tell exercise from stress, heat, caffeine or illness.** Your sitting heart rate today was about 90–100, only about 15–20 BPM below the threshold, so a warm room or a coffee can tip it over.
- **Two detectors with different rules:**
  - `ActivityDetector`: 60% of max HR. Its results become the "Workout detected" cards.
  - `CalibrationEngine.activities`: zone 1 or higher, meaning 40% of heart-rate *reserve*, for 10 minutes. Its results decide which minutes count as active calories.
  - They can disagree, so calories can count an effort that never appears as a workout, and the other way round.
- **Type guessing is weak:** heart-rate level doesn't separate running from cycling or a hard walk.
- **No learning:** your confirm/dismiss answers are stored but never change the threshold.

**Improve:**
1. **Gate on movement.**
   - Walking or running: require step cadence, from the band's step counter (about 2 per second when walking) or the iPhone.
   - Workouts without steps (strength, cycling): require motion above a floor, or confirmation.
   - Published workout detectors threshold both accelerometer and heart rate.
2. **Classify from cadence:**
   - Walking: about 90–120 steps/min.
   - Running: about 150–180 steps/min. Watch for a double-frequency error, which a patent describes halving for.
   - High heart rate with low cadence and steady motion: cycling or rowing.
   - Bursty heart rate with sets: strength.
3. **One detector**, used for both cards and calories.
4. **Personalise the threshold:** set it relative to your own daytime median plus a margin, and move it up after dismissals and down after confirmations.

## 3. Resting heart rate (priority 1)

**How it works:**
- Each night: the lowest 5-minute average of asleep minutes.
- For zones: once 4 nights exist, the median of the last 14 nights, moving at most about 2 BPM a week.
- Recovery compares each night's value with the last 28 nights.

**Good at:**
- One definition used everywhere.
- The drift limiter stops zones jumping.
- Works without HRV.

**Lacking:**
- **"Lowest 5 minutes" is an extreme value, so one glitch sets it.**
  - Today 15:56–16:05 shows 42–58 BPM with almost no movement, while minutes either side were about 80–90.
  - That's either the band briefly locking onto half your heart rate, or a real drop. Nothing in the code checks.
  - The same thing at night would set resting HR, Recovery and zones too low.
- **No movement or quality filter** on the minutes it uses.

**Improve:**
1. **Reject implausible drops:** a minute more than about 25% below its 5-minute neighbours, or a minute whose beat-to-beat intervals disagree with its BPM.
2. **Use a robust value:** the 10th percentile of still, asleep minutes, or the mean of the lowest stable 30 minutes, rather than the single lowest 5-minute window.
3. **Use only motionless minutes**, ideally in the deepest, steadiest part of the night.

## 4. HRV (priority 2)

**How it works:**
- RMSSD from beat-to-beat intervals.
- Differences are taken only within one per-second record, never across records, so missing beats aren't bridged.
- Pairs that differ by more than 20% are dropped.
- Pairs are pooled into 5-minute windows of at least 20 pairs. The night value is the median of at least 6 windows.
- If any live-stream minutes with RMSSD exist for the night, their mean is used instead.

**Good at:** artefact rejection, never bridging gaps, refusing to report without enough data.

**Lacking:**
- **Sparse data:** about 37% of beats carry intervals. Today gave 3,156 pairs in 408 minutes, about 8 per minute.
- **Whole-night median mixes stages.** HRV changes a lot between deep, light and REM sleep and through the night, so night-to-night comparisons get noisy. WHOOP says it measures HRV in the last 5 minutes of slow-wave sleep for exactly this reason.
- **Source mixing:** `Stats.mean(rmssdValues) ?? nightRMSSD(...)` prefers live-stream minutes if *any* exist. A night where the app streamed briefly is computed differently from one where it didn't.
- **Raw RMSSD is skewed**, so baselines and z-scores on it are distorted. The sports-science convention is ln(RMSSD).

**Improve:**
1. Compute from **one source** (history records), always.
2. Use a **fixed physiological window:** the steadiest low-HR, low-motion stretch in the last third of the night, or the last deep-sleep-like stretch once stages are trustworthy.
3. Store and compare **ln(RMSSD)**. Track the 7-day rolling mean and coefficient of variation (Plews et al.).
4. Show a quality flag when fewer than about 6 good windows exist.

## 5. Sleep onset and wake (priority 2)

**How it works:**
- Searches 18:00–14:00.
- "Asleep" means the 10-minute rolling median heart rate is at least 10 BPM below the previous day's daytime median, held for 20 minutes.
- Gaps under 60 minutes are merged, and the longest period is kept.
- Awakenings are 3 or more minutes at 15 BPM or more above the sleeping median, or in strong movement.

**Good at:**
- Never claims sleep where nothing was measured.
- Merges brief awakenings.
- Copes with gaps.

**Lacking:**
- **Heart rate falls slowly after you fall asleep and rises before you wake**, so onset tends to be late and wake early by several minutes.
- **Lying still and awake** (reading, phone) with a calm heart rate counts as sleep.
- **Movement is only used for awakenings,** with the same self-relative threshold as naps.
- **One main period per night**, so split sleep or shift work is lost.

**Improve:**
- **Add movement as a primary signal.**
  - van Hees' HDCZA finds the sleep window from arm-angle changes alone. It agreed with lab sleep studies with a C-statistic of 0.83–0.86, and an independent paediatric comparison found it the most accurate of the algorithms tested.
  - Recent work combines optical heart rate with the accelerometer for sleep/wake.
  - So: arm-angle stillness proposes the window, the heart-rate drop confirms it, and onset is set by stillness, not by heart rate.
- Use absolute movement thresholds.

## 6. Recovery (priority 2)

**How it works:**
- z-scores of last night against the previous 28 nights (minimum 4).
- Weights: HRV 60%, resting HR 25% (inverted), sleep performance 15%. Without HRV: resting HR 70%, sleep 30%.
- Standard-deviation floors stop tiny changes producing huge scores.
- A logistic curve centres a typical night at 58. Green from 67, yellow from 34.

**Good at:**
- Personal baseline.
- Floors.
- An "Early" flag until 14 nights.
- Matches WHOOP's stated emphasis: HRV first, resting HR next, sleep smaller.

**Lacking:**
- **The weights and centre are our own choice**, never validated.
- **Mean and SD of raw values:** one bad night skews the baseline, and raw RMSSD is skewed.
- **Inherits** every resting-HR and HRV weakness above.
- **No other signals:** no skin-temperature or respiratory-rate input, both of which WHOOP's health features use.

**Improve:**
1. Use ln(RMSSD), and **median/MAD** instead of mean/SD for the baseline.
2. Add a **skin-temperature deviation** penalty. We already have the raw value per night.
3. Add respiratory rate when it becomes decodable.
4. Check the score against how you feel: log a 1–5 "how do you feel" each morning for a few weeks, then tune the weights against it.

## 7. Calories (priority 2)

**How it works:**
- Resting: Mifflin-St Jeor BMR, spread per minute.
- Active: Keytel et al. (2005) heart-rate equation minus resting. Counted only for minutes at zone 1 or higher (40% of HR reserve, about 119 BPM for you) *and* inside a confirmed workout or a 10-minute heart-rate-detected activity.

**Good at:**
- Published equations.
- Won't count stress heart rate outside activities as burn.

**Lacking:**
- **Everyday movement counts as zero.** About 3,400 band steps today added no active calories, because walking around rarely reaches zone 1. Daily totals will run low.
- **Keytel was derived from exercise heart rates.** Studies of heart-rate methods find them weak at low intensity, which is where most of the day is spent.
- **Generic equations:** BMR is typically within about ±10% for an individual, and the Keytel coefficients are population averages.

**Improve:**
1. **Add steps:** walking costs roughly 0.5 kcal per kg per km. Steps × stride × weight gives an everyday-movement term for minutes below zone 1.
2. **Move toward FLEX-HR:** below a personal "flex" heart rate use resting rate plus movement, above it use heart rate. Combined heart rate and accelerometer estimates beat either alone.
3. Keep the per-source breakdown honest: everyday movement becomes its own row.

## 8. Strain (priority 3)

**How it works:**
- Load = Σ minutes × zone number (1–5), with zones from 40/60/70/80/90% of heart-rate reserve.
- Score = 21 × (1 − e^(−load/200)).
- Uses 70 BPM as resting until a resting HR is measured.

**Good at:**
- Simple and monotonic.
- Saturates like WHOOP's 0–21 scale.
- Uses heart-rate reserve.

**Lacking:**
- **Step function:** 118 BPM adds nothing, 119 adds a full zone-1 minute.
- **Long low-level days score near 0.** Today's 0.1 is an example.
- **Max HR from age is ±10 BPM or so for an individual**, which shifts every zone.
- **The scale of 200 is untuned.**

**Improve:**
1. **Banister TRIMP per minute:** intensity × e^(1.92 × HRR) for men, e^(1.67 × HRR) for women. That's continuous, with no cliffs, and the standard in training-load research.
2. **Learn max HR:** raise it whenever a clean reading above it is seen.
3. **Tune the 0–21 mapping** so a typical hard hour lands where you expect.

TRIMP's known limits are intervals, strength and swimming, so keep a manual effort rating (already in Calibration) as a correction.

## 9. Sleep stages (priority 3: hide or rebuild)

**How it works:**
- Deep = the lowest 30% of smoothed heart rate with below-median wobble.
- REM = the top 25% of wobble.
- Everything else is light, with smoothing and a 5-minute minimum.

**Good at:** produces plausible-looking charts.

**Lacking:**
- **No validation at all.**
- Even commercial wrist devices that use machine learning on HRV, motion and temperature reach only modest four-stage agreement with lab sleep studies.
- Ours uses heart-rate level and wobble only, with sparse beat intervals.

**Improve:** pick one of two paths.
- **Hide it:** remove stages from user screens until they're validated. Keep total sleep, awakenings and timing, which are much more reliable.
- **Rebuild it:** per-epoch HRV, motion and time-of-night priors (deep early, REM late), then validate against a reference before showing it.

## 10. Smaller models

- **Sleep need:** 7.5 h + 3 min per strain point + half of the last 3 nights' shortfall (capped at 2 h) − confirmed naps (capped at 90 min). Reasonable. It needs your own baseline hours, and that's already a setting.
- **Consistency:** average deviation of bed and wake times over 4 nights. Fine.
- **Skin temperature:** raw sensor value against 7 nights' mean ± 2 SD. Correct to keep it relative. Fit and room temperature move it.
- **Steps:** iPhone pedometer today. The band counter is a candidate (see `band-steps-spo2-research.md`).

---

## Suggested order

1. **Bugs:**
   - Absolute stillness for naps.
   - One HRV source.
   - Resting-HR artefact rejection.
   - One workout detector.

   Small, testable changes. I can add a check for each using today's data, including the false nap.
2. **Use motion and steps everywhere:**
   - Workout gating and type from cadence.
   - Arm-angle sleep window.
   - Everyday-movement calories.
3. **Better statistics:**
   - ln(RMSSD) and robust baselines in Recovery.
   - A fixed HRV window.
   - TRIMP strain.
   - Learned max HR.
4. **Stages:** hide now, rebuild later with validation.

## How we'd know it worked

There is no ground truth yet. Cheap references:

| Checks | Reference |
|---|---|
| Sleep window | Your own bed and wake times |
| Workout detection | Your confirm/dismiss answers |
| Steps | iPhone pedometer |
| Resting HR and HRV | A chest strap for a few nights; HRV apps accept them |
| Recovery weights | A 1–5 morning feel score |

Two weeks of nights and normal days would be enough to tune the constants in `HealthConstants.swift`.

## Sources

- van Hees et al. 2018, sleep window from wrist accelerometer (HDCZA): [Scientific Reports](https://discovery-pp.ucl.ac.uk/10055119/1/s41598-018-31266-z.pdf)
- van Hees et al. 2015, sustained inactivity as sleep: [PLOS One](https://pmc.ncbi.nlm.nih.gov/articles/PMC4646630)
- Comparison of accelerometer sleep algorithms: [PMC7420526](https://pmc.ncbi.nlm.nih.gov/articles/PMC7420526)
- Sleep/wake change-point detection with PPG and accelerometer: [npj Digital Medicine](https://www.nature.com/articles/s41746-023-00802-1.pdf)
- WHOOP on HRV during the last slow-wave sleep: [WHOOP podcast 194](https://www.whoop.com/ie/en/thelocker/podcast-194-understanding-heart-rate-variability-and-its-performance-potential/)
- Recovery drivers: [Sleep.com on WHOOP](https://www.sleep.com/sleep-tech/whoop)
- TRIMP and heart-rate-reserve weighting: [three-dimensional impulse-response model](https://arxiv.org/pdf/2503.14841)
- TRIMP method comparison: [Western Sydney University](https://researchers.westernsydney.edu.au/en/publications/a-comparison-of-methods-for-the-calculation-of-the-training-impul/)
- Workout detection from heart rate and accelerometer: [US patent 10568549](https://image-ppubs.uspto.gov/dirsearch-public/print/downloadPdf/10568549)
- Cadence halving: [US patent 11298036](https://image-ppubs.uspto.gov/dirsearch-public/print/downloadPdf/11298036)
- Heart rate plus accelerometry for energy expenditure:
  - [Johansson et al. 2006](https://resolve.cambridge.org/core/services/aop-cambridge-core/content/view/6D6C8EC63D72A2A1D18C912272CF0DE5/S0007114506000845a.pdf/accelerometry-combined-with-heart-rate-telemetry-in-the-assessment-of-total-energy-expenditure.pdf)
  - [piecewise HR + counts model](https://www.cea.fr/cea-tech/leti/Lists/Publications/StructuredDisplayForm.aspx?ID=380)
  - [PMC10905789](https://pmc.ncbi.nlm.nih.gov/articles/PMC10905789)

## Calories: oxygen-uptake model (added 10 Nov 2026)

Replaces Keytel 2005 for active calories. Modelled on the published structure of Firstbeat's method (licensed by Garmin); Firstbeat's neural network, respiration and on/off-kinetics inputs are not public and are not reproduced.

- VO2max: Uth et al. 2004, 15.3 × HRmax / resting HR (overnight), kept within 25–70 ml/kg/min.
- Oxygen uptake: Swain 1997, % heart-rate reserve ≈ % VO2 reserve, anchored to the heart rate while awake and still (median of still daytime minutes; overnight resting + 15 until measured).
- kcal per litre O2: 4.69 at rest to 5.05 at maximum (fat to carbohydrate).
- Counting: workouts and detected activities from the flex heart rate (awake + 15% of reserve) up; other minutes only when wrist movement ≥ 150 mg, so a raised heart rate while sitting stays at rest.
- On 10 Nov data (6.8 h): everyday movement adds ~80 kcal that Keytel gave 0; activity-level minutes give ~30% less than Keytel at 100–130 BPM, more above 150 BPM.
- Firstbeat's own validation: total-energy MAE 79 kcal vs 93–181 kcal for HR-only methods ([Pulkkinen 2005](https://www.firstbeat.com/wp-content/uploads/2015/10/pulkkinen_et_al_acsm_2005_congress.pdf)); 288 vs 315 kcal measured over 25 daily tasks ([Smolander 2007](https://www.firstbeat.com/wp-content/uploads/2015/10/smolander_et_al_ecss_2007_congress-1.pdf)).
- Untested against any reference here. Biggest uncertainty: VO2max from resting HR.
