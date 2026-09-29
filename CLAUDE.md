# Thesis project: climate shocks, agricultural production and child nutrition in Bangladesh

This file is the full handoff for this project. Read it completely before doing anything.
It records every decision made so far with the student (Kabir) and his supervisor
(Syed Shahadat Hossain, PhD, ISRT, University of Dhaka), including decisions that were
later reversed, so you do not re-propose abandoned designs.

---

## 1. How to work with Kabir

- He works iteratively and precisely. When you change code, say exactly which lines change and why.
- During design discussions, ask questions and wait. Only write code when he asks for code.
- Do not make silent research decisions. If a definition is ambiguous (thresholds, windows,
  aggregation), stop and ask. Several earlier mistakes came from assuming.
- The supervisor changes the design between meetings. The CURRENT spec is section 6.
  Anything in section 9 ("Abandoned") must not be reintroduced unless Kabir asks.
- Never modify raw input files. Write derived data to new files.
- Kriging is slow (hours). Always cache and reuse `district_day_full.rds`.
- Language: R (tidyverse style, `dplyr`, `lavaan`, `sf`, `gstat`, `lubridate`, `haven`, `readxl`).

## 2. Research question

Does temperature and rainfall exposure during a child's first ~1000 days affect child
nutrition, and is that effect mediated by agricultural production? Also: has this
relationship changed across MICS 2012, 2019 and 2025 (trend over time)?

Conceptual path: Climate exposure -> Agricultural production -> Child nutrition,
plus a direct Climate -> Nutrition path, adjusting for covariates.

Framing: associational, not causal. Report "indirect/mediated associations".

Original proposal (for reference only; much has changed): multilevel GSEM with CAR spatial
random effects, dietary diversity (MDD) as a second mediator, district-level production,
GDD/HDD as continuous degree-day sums. See section 9 for what was dropped.

## 3. Environment and files

- OS: Windows. Working directory: `D:/Monayer`
- Raw inputs (all in `D:/Monayer`):

| File | Contents |
|---|---|
| `ch2012.sav`, `ch2019.sav`, `ch2025.sav` | MICS child datasets |
| `Max_Temp.xlsx` (sheet `Max_Temp_1981_2025`) | BMD station daily max temp. Cols `St_ID, Year, Month, Date, MaxT`. Missing = `****` |
| `Min_Temp.xlsx` (sheet `min_temp_1981_2025`) | Same, col `MinT` |
| `Rainfall.csv` | Station daily rain. Cols `Station, Year, Month, Day, Rainfall`. Missing = `**`. Covers 2007-2025 only, 47 stations |
| `Agri_production.xlsx` | NATIONAL annual series 1980-2024. Sheets: `Aus `, `Aman `, `Boro `, `Total Rice, All types `, `Wheat `, `Maize `, `Potato` (note trailing spaces in names). Key col `Production (Tons)`; also area, yield, price, and ~55 national climate/economic columns identical across sheets |
| `districts_lat_lon.csv` | 64 district centroids: `district, lat, lon` |
| `station_district_crosswalk.csv` | Station coords + district (built in this project, see 5.3) |

- Existing derived files (may exist on disk):
  - `district_day_full.rds`: daily kriged `maxt_pred, mint_pred, rain_pred` per district x date. REUSE THIS.
  - `ch_final_v3.rds`: OLD spec (Boro + potato/maize). Superseded; do not analyse.
- Existing scripts:
  - `01_prerequisites.R`: MICS merge, station cleaning, kriging, HH7A crosswalk. STILL VALID (see section 5).
  - `02_*`, `03_*`, `04_final_exposures.R`, `05_final_multigroup_sem.R`: OLD specs, superseded.

## 4. Data facts established

### MICS
- Merge = columns common to all 3 rounds, plus `survey_year`. Rows: 2012 = 23,402; 2019 = 24,686; 2025 = 24,680 (72,768 total).
- 2012 uses different birth-date names: rename `AG1D->UB1D, AG1M->UB1M, AG1Y->UB1Y, AG2->UB2` before merging.
- Key variables:

| Var | Meaning |
|---|---|
| `HH7A` | District (labelled; convert with `as.character(as_factor(HH7A))`) |
| `UB1D, UB1M, UB1Y` | Child birth day, month, year. Missing codes 99 / 99 / 9999; also treat any day outside 1-31 or month outside 1-12 as NA |
| `CAGE` | Child age in months |
| `HL4` | Sex |
| `HAZ2, WAZ2, WHZ2` | WHO z-scores (height-for-age, weight-for-age, weight-for-height). Use these, not the NCHS `HAZ/WAZ/WHZ` |
| `HAZFLAG, WAZFLAG, WHZFLAG` | WHO implausibility flags |
| `wscore`, `windex5` | Wealth score / quintile |
| `melevel`, `ED5A` | Mother's education / highest level attended |

- Build birth date with `lubridate::make_date()` (returns NA for invalid combos; `as.Date(paste())` errors on the whole vector).
- Outcomes: stunted = `HAZ2 < -2`, wasted = `WHZ2 < -2`, underweight = `WAZ2 < -2`.
- Every district has children in every round (no empty district x round cells), so multi-group SEM by round is feasible.

### HH7A -> district crosswalk
Fuzzy match (normalised names, edit distance <= 2) against `districts_lat_lon.csv`, then these manual overrides:

| HH7A label | district |
|---|---|
| Brahmanbaria | Bbaria |
| CHATTOGRAM CITY CORPORATION | Chittagong |
| DHAKA SOUTH CITY CORPORATION | Dhaka |
| DHAKA NORTH CITY CORPORATION | Dhaka |
| Kishorganj | Kishoregong |
| Nawabganj | Chapai |

After this all 72,768 rows match. Join keys must both be plain character (a factor/character mismatch silently matched nothing once).

### Agricultural data
- National only. No district breakdown exists. So production varies by year only, not district.
- Year = HARVEST year for season crops.
- Anomaly definition: `(Y_t - mean(Y)) / mean(Y)` over the full series.

## 5. Climate pipeline (implemented in `01_prerequisites.R`, still valid)

### 5.1 Station temperature cleaning (apply in this order)
1. Read with `sheet = 1`, add `excel_row = row_number() + 1`.
2. CORRECTION 1: rows 219923-219952 (St_ID 10208, Rangpur) are labelled Year 2023 but are April 2024 (they sit between 2024-03-31 and 2024-05-01). Set Year = 2024. Same rows in both files.
3. CORRECTION 2: drop rows 221810-221839. They are a misplaced copy of St_ID 41851's June 2024 inside St_ID 10120's block. The correct copy exists elsewhere. 10120's June 2024 stays missing.
4. Treat `****`, `***`, `**`, `*`, blank, `NA`, `N/A` as missing.
5. CORRECTION 3: drop rows whose date doesn't parse (template rows with Day 31 in 30-day months; already `****`).
6. Genuine gaps left as missing: 11316 Jun-Oct 2025, 11921 Sep-Oct 2025, 41850 Sep 2023.
7. St_ID 41851's 2021 block is out of row order but correctly labelled: no action.
Result: 254,857 station-days, 44 stations, ~2.6% missing.

### 5.2 Rainfall cleaning
Missing = `**`. Rename `Station -> St_ID`. Drop unparseable dates. `distinct(St_ID, date)` as a guard.

### 5.3 Station coordinates
From the BMD "Observational sites" table plus web lookups. Unresolved and EXCLUDED: 91850 (30 rows, unknown), and rainfall-only 41906, 41925, 41930, 41948.
Stations added via web search use upazila-town coordinates, not exact station siting (a methods limitation): 41850 Tetulia (Panchagarh), 41851 Dimla (Nilphamari), 41856 Rajarhat (Kurigram), 41881 Badalgachhi (Naogaon), 41897 Tarash (Sirajganj), 41927 Kumarkhali (Kushtia), 41902 Nikli (Kishoreganj). 41888 Netrokona and 41938 Gopalganj use the district centroid.

### 5.4 Kriging station -> district
- Ordinary kriging to the 64 district centroids, one day at a time.
- Variogram: one spherical model per calendar month per variable, fitted on all days of that month pooled (per-day variograms are unstable with ~40 stations).
- Skip a day if fewer than 5 stations report. Rainfall predictions floored at 0.
- Output: `district_day_full.rds` with `district, date, maxt_pred, mint_pred, rain_pred`.

## 6. CURRENT SPECIFICATION (as of 2026-09-29)

Focus now: Aus rice and stunting only. Build the code so another crop (e.g. Aman) or
outcome (wasting, then underweight) can be added by editing a settings table, not the logic.

### 6.1 Why Aus
Supervisor dropped potato and maize (overlapping seasons) and Boro (winter crop).
Aus is the pre-monsoon/early-monsoon crop (roughly mid-March to July).

### 6.2 Three yearly windows per child
- Y1 = [birth - 1 year, birth)
- Y2 = [birth, birth + 1 year)
- Y3 = [birth + 1 year, birth + 2 years)

### 6.3 Season assignment (option b, chosen by Kabir)
Each window is assigned ONE whole Aus season, from one calendar year, so seasons are never split.
Rule to implement: the season year for window Yk is the calendar year whose Aus harvest
reference date (July 31) falls inside that window. A 12-month window contains exactly one
July 31, so this is unambiguous. Confirm this rule with Kabir before coding.

### 6.4 Growth stages and extreme thresholds (Yoshida 1981, IRRI; widely cited in BRRI literature)

| Stage | Dates within season year (PROPOSED, NOT YET CONFIRMED) | Cold day: MinT <= | Hot day: MaxT >= |
|---|---|---|---|
| s1 Germination & seedling | Mar 15 - Apr 15 | 12 | 35 |
| s2 Vegetative / tillering | Apr 16 - May 31 | 16 | 33 |
| s3 Reproductive (panicle initiation + flowering) | Jun 1 - Jun 30 | 22 | 35 |
| s4 Ripening / grain filling | Jul 1 - Jul 31 | 18 | 30 |

- Hot days judged on daily MAX temp; cold days on daily MIN temp (confirmed).
- Tillering/PI/anthesis/ripening values were confirmed from a published reproduction of the Yoshida table; germination/seedling values should be checked against the source.
- The stage DATES are the weakest part and must be confirmed with the supervisor.
- Supporting facts: BAMIS says Aus ideal day temp 20-36C, tolerates 19-40C, flowering 22-23C, grain formation 20-21C. Literature: optimum transplanting mid-March to early May; critical development period March-April; harvest July-August.
- Keep thresholds and dates in one editable settings table.

### 6.5 Variables to build (per child, in the child's own district, from `district_day_full`)
- 24 base counts: `aus_s{1..4}_hot_y{1..3}` and `aus_s{1..4}_cold_y{1..3}`.
- Derived (computed afterwards from the base counts):
  - Non-optimal days per stage-window: `aus_s{k}_nonopt_y{j}` = hot + cold.
  - 3-year totals: per stage (`aus_s{k}_hot_total`, `_cold_total`, `_nonopt_total`) and overall.
- Rainfall anomaly per window: `aus_rain_anom_y{1..3}` = (rain during that season year's Aus season in the district - district long-term mean for the same season) / long-term mean. Season span for rainfall = s1 start to s4 end.
- Mediators (3): `aus_prod_anom_y{1..3}` = Aus national production anomaly for each window's season year.
- Outcome: `stunted` (0/1).
- Covariates in use so far: `wscore`, `HL4`. Proposal also lists maternal education, child age, residence, maternal age, household size.
- Also keep: `survey_year`, `district`, `birth_date`, `CAGE`, the season year per window.

### 6.6 Sample restriction
Supervisor: analyse only children aged 24+ months (`CAGE >= 24`), because the window runs
to birth + 2 years; for younger children part of the window is after measurement.
Build the dataset for ALL children and add a flag `age_24plus`. Apply the filter at analysis time.

### 6.7 Coverage flags to add
- Temperature ends Dec 2025; rainfall starts Jan 2007 (temperature starts 1981).
- Add flags for any window whose season year lacks full temperature or rainfall coverage, instead of silently producing understated counts.

### 6.8 Model (after the dataset is built and validated)
- lavaan SEM: mediator equations `aus_prod_anom_y{j} ~ stage hot/cold counts + rain anomaly` for that window, outcome equation `stunted ~ all exposures + mediators + covariates`. Exact equation form not yet agreed; ask Kabir before writing it.
- Trend: multi-group SEM with `group = "survey_year"`, `cluster = "district"`, `ordered = "stunted"`. Fit configural, threshold-invariant (`group.equal = "thresholds"`), and fully constrained (`c("thresholds","regressions")`), and compare with `anova()`.
- Watch for collinearity among the many count variables; check correlations first.
- CAR spatial effects are NOT implemented (lavaan can't do them). Planned later via brms/INLA/spaMM.

## 7. Immediate next task

Write the Aus dataset script (e.g. `06_aus_dataset.R`) that:
1. Loads `district_day_full.rds` (no re-kriging) and rebuilds `ch_merged_agri` from section 4 (or reuses `01_prerequisites.R` sections 1 and 5).
2. Builds windows, season years, the 24 counts, derived aggregates, 3 rain anomalies, 3 production mediators, `stunted`, `age_24plus` and coverage flags.
3. Is vectorised (join child x window to a precomputed district x season-year x stage table), not a per-child loop. Earlier per-child loops over 72,768 children were very slow.
4. Saves `ch_aus_v1.rds` and exports an Excel file for supervisor validation (key columns sheet + production sheet).
5. Includes sanity checks: count per stage-window can never exceed that stage's day length; print a few children in full for manual checking.

Before coding, confirm with Kabir: stage dates, the July-31 season-assignment rule, and the rainfall anomaly season span.

## 8. Lessons from earlier mistakes (avoid repeating)
- Judging GDD and HDD on the same max temp made them sum to the season length (perfect collinearity).
- Comparing a 20C "average day" threshold against nightly minimums made cold days equal winter length.
- Summing two crops' day counts exceeded the number of days in the window.
- Always check each count against its maximum possible value.
- A window was once coded as birth-24/+12 months when it should have been birth-12/+24; double-check window direction.

## 9. Abandoned designs (do not reintroduce unless asked)
- Fixed 35C/10C hot/cold thresholds; window-mean thresholds; rolling 80th/10th percentile thresholds with 5-year lookback.
- 1000-day window of birth-635/+365 days; birth-24/+12 months.
- Total rice; Aus+Aman+Boro+wheat+maize+potato (6 mediators); Boro + combined potato/maize (2 mediators).
- Continuous GDD/HDD degree-day sums; single full-window day counts; national-mean temperature for crop exposure.
- Wasting/underweight modelled now (they come later, one at a time).
- Dietary diversity mediator (MDD not common across all 3 rounds).
- Lagged birth-year production (lag0/lag1/lag2 joins).

## 10. Other references
- Yoshida, S. (1981). Fundamentals of Rice Crop Science. IRRI.
- BAMIS Aus rice page: https://www.bamis.gov.bd/en/crops/view/7/
- A case-crossover temperature-mortality paper (percentile thresholds, DLNM) was reviewed; useful only as precedent for percentile thresholds and sensitivity-analysis structure.
- Planned sensitivity analyses: alternative thresholds, alternative stage dates, alternative windows.
