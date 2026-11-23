# Valenbisi Pipeline

Valenbisi's app shows how many bikes and free docks each station has right now, but not what you will find when you actually get there. This project collects the availability of every station every 30 minutes and uses that history to show, for each station and time of day, how often there was a bike to take or a free dock to park. The goal is to help people in Valencia decide whether a trip by Valenbisi is worth it.

An automated data pipeline that collects real-time availability from **Valenbisi**, the public bike-sharing system in Valencia (Spain), and stores it as a historical dataset in PostgreSQL for later analysis.

Every 30 minutes, a GitHub Actions job pulls the status of all ~270 stations from the City of Valencia's open data API and loads it into a Supabase (PostgreSQL) database. The job is triggered from the database itself with `pg_cron`.

Once a day, a **dbt** project turns the raw readings into clean, analysis-ready tables, and **47 automated data tests** check them. The final analysis (`notebooks/02_final_analysis.ipynb`) and a Power BI dashboard read only those tables.

## Architecture

```mermaid
flowchart LR
    G[Supabase pg_cron<br/>every 30 min] -->|workflow dispatch| F[GitHub Actions<br/>collect.yml]
    F -->|runs| C
    A[Valencia Open Data API<br/>geoportal.valencia.es] -->|HTTP / JSON| B[extract.py<br/>fetch + retries]
    B --> C[load.py<br/>transform + load]
    C -->|upsert| D[(stations)]
    C -->|insert, skip duplicates| E[(availability)]
    D --> S[dbt staging<br/>views]
    E --> S
    S --> I[dbt intermediate<br/>cleaning rules]
    I --> M[dbt marts<br/>tables + tests]
    H[GitHub Actions<br/>transform.yml, daily] -->|dbt build| M
    M --> N[Notebook 02<br/>charts]
    M --> P[Power BI<br/>dashboard]
```

| Step | What it does |
|------|--------------|
| **Extract** (`src/extract.py`) | Queries the ArcGIS REST endpoint for all stations. Retries up to 3 times with increasing waits and fails loudly if the API returns an error or a truncated response. |
| **Transform + Load** (`src/load.py`) | Splits each record into static station data and a time-stamped availability snapshot, converts types (epoch ms → `TIMESTAMPTZ`, `'T'/'F'` → `BOOLEAN`) and writes both to PostgreSQL in a single transaction. |
| **Orchestration** (`.github/workflows/collect.yml`) | Runs the pipeline on GitHub-hosted runners. Database credentials are injected from GitHub Secrets. |
| **Scheduling** (`sql/schedule.sql`) | A `pg_cron` job in Supabase calls GitHub's workflow dispatch API every 30 minutes through `pg_net`. |
| **Transform + test** (`dbt/`, `.github/workflows/transform.yml`) | Every day, dbt applies the cleaning rules, builds the analysis tables in the `analytics` schema and runs 47 data tests. It also checks that the collection is still running (source freshness) and publishes the documentation site. |
| **First analysis layer** (`sql/setup.sql`) | The holidays table, plus the original SQL view. The view was the first version of the analysis and is superseded by the dbt marts. |

## Data model

Two tables, following a dimension / fact split:

**`stations`** — one row per station (dimension). Updated in place if a station's details change.

| Column | Description |
|--------|-------------|
| `station_id` | Station number (primary key) |
| `name` | Station name |
| `address` | Street address |
| `latitude`, `longitude` | Location (WGS84) |

**`availability`** — one row per station per measurement (fact). Rows are only ever appended.

| Column | Type | Description |
|--------|------|-------------|
| `station_id` | `INTEGER` | FK → `stations.station_id` |
| `updated_at` | `TIMESTAMPTZ` | When the station reported this measurement |
| `fetched_at` | `TIMESTAMPTZ` | When the pipeline downloaded it |
| `is_open` | `BOOLEAN` | Station operational status |
| `bikes` | `INTEGER` | Bikes available |
| `free_docks` | `INTEGER` | Empty docks |
| `total_docks` | `INTEGER` | Station capacity |

Primary key: `(station_id, updated_at)`.

On top of the raw tables:

**`holidays`** — public holidays in Valencia, so that a holiday on a weekday is not counted as a working day.

**`station_hourly_availability`** (view) — one row per station, type of day (`workday` or `weekend_or_holiday`) and hour of the day in Valencia time.

| Column | Description |
|--------|-------------|
| `measurements` | Number of measurements behind the percentages |
| `pct_bike_available` | % of measurements with at least 1 bike |
| `pct_dock_available` | % of measurements with at least 1 free dock |
| `pct_dock_with_margin` | % of measurements with at least 3 free docks |

## dbt layer

The cleaning rules discovered in `notebooks/01_analysis.ipynb` were first applied in pandas. They now live in dbt, so they run on every build, are tested automatically and are the same for every consumer (notebook, dashboard, SQL).

```
sources (public)        staging (views)       intermediate (view)     marts (tables, schema analytics)
availability  ───────►  stg_availability ──►  int_readings_clean ──►  fct_readings ──► fct_station_hourly ──► mart_station_profile
stations      ───────►  stg_stations    ─────────────────────────────►  dim_stations       mart_trip_success
holidays      ───────►  stg_holidays                                    rpt_cleaning_log
```

| Model | Grain | What it is for |
|-------|-------|----------------|
| `int_readings_clean` | station × 30-min slot | The four filtering rules: reliable period, no stale readings, no out-of-service readings, one reading per slot |
| `fct_readings` | station × 30-min slot | Clean readings in Valencia time, with type of day and has-bike / has-dock flags |
| `fct_station_hourly` | station × date × hour | Counts (not percentages), so any tool can aggregate correctly. Feeds the dashboard |
| `mart_station_profile` | station × type of day × hour | The project's question in SQL: % of readings with a bike / a free dock |
| `mart_trip_success` | trip × type of day × hour | Paired readings of origin and destination; trips are configured in `dbt_project.yml` |
| `rpt_cleaning_log` | cleaning step | Rows removed by each rule, recomputed every day |
| `dim_stations` | station | Readable name, location and current capacity |

**Data tests** (47, run by `dbt build`):
- **Source:** primary key unique, foreign key to stations valid, no negative counts, `bikes + free_docks <= total_docks`, coordinates inside Valencia.
- **Cleaning:** one reading per station and slot, no out-of-service or stale readings left, nothing before the start of collection.
- **Marts:** percentages between 0 and 100, accepted values for the type of day, and a trip can never succeed more often than either of its two conditions.
- **Monitoring:** source freshness (warn after 2 hours without new data, error after 12), a warning if the pipeline went more than 2 hours without a run in the last week, an error if cleaning removes more than 25% of the readings, and a warning if the API's `is_open` flag ever stops being always `true`.

The cleaning in dbt was checked against the original pandas code from notebook 01: on the same input, both keep exactly the same readings, row for row.

## Using the data

The mart `mart_station_profile` answers the question the project exists for. For example, how easy is it to park at station 105 (next to the UPV campus) on a working day, hour by hour:

```sql
SELECT local_hour, readings, pct_bike, pct_dock, pct_dock_with_margin
FROM analytics.mart_station_profile
WHERE station_id = 105
  AND day_type = 'workday'
ORDER BY local_hour;
```

And whether a whole trip works, from paired readings of both stations:

```sql
SELECT local_hour, paired_readings, pct_bike_at_origin, pct_dock_at_destination, pct_naive, pct_trip
FROM analytics.mart_trip_success
WHERE origin_id = 74 AND destination_id = 105
  AND day_type = 'workday'
ORDER BY local_hour;
```

The exploration that led to this design is in [`sql/analysis.sql`](sql/analysis.sql) (written against the first SQL view).

How to read the numbers:

- They are **historical frequencies, not predictions**: "on working days at 9:00 this station had a free dock in X% of the measurements".
- The marts are computed over all the data collected so far, so the figures get more reliable every week. Always check `readings`: a percentage over a handful of rows means little.
- Collection every 30 minutes started on 3 October 2026. Earlier rows are kept in the raw table but left out of the marts.

## Analysis results

The final analysis is in [`notebooks/02_final_analysis.ipynb`](notebooks/02_final_analysis.ipynb). It reads only the dbt marts. The exploration and the cleaning rules came first, in [`notebooks/01_analysis.ipynb`](notebooks/01_analysis.ipynb).

Data: 3 October to 5 November 2026, **18 working days with complete collection**; cleaning keeps 92.3% of the readings. Figures are historical frequencies on working days, with 95% confidence bands where it matters.

**A real trip: station 74 (Mercado Algirós) to station 105 (UPV).**

![Trip 74 to 105 by hour](docs/img/trip_74_105.png)

- **Before 8:00 the trip worked every time** (100% at 6:00 and 7:00).
- **From 8:00 to 10:00 it worked only 35-50% of the time** (50% at 8:00, band 35-66%), recovering to 67% at 11:00.
- At 8:00 and 9:00 the destination is the bottleneck (a free dock at 105 only 53% and 46% of the time); by 10:00 the origin fails too (a bike at 74 only 65% of the time).
- Multiplying the two separate probabilities gives almost the same result as pairing the readings (at most 3 points apart). The first analysis, with 6 working days, suggested the pairing mattered; with 18 there is no evidence that it does.

**The whole city at 8:00.**

![Stations most often full at 8:00](docs/img/hardest_stations_at_8.png)

- The stations that fill up are concentrated around the UPV campus and Avenida de los Naranjos: **6 of the 10 stations most often full** are there. The worst had no free dock in 67% of readings; station 105, in 47%.
- Hospital Nueva Fe (188) is also in the top 10, another large destination at the start of the working day.
- With 36 readings per station, the ranking separates the campus area from the rest of the city but cannot order the stations inside it.

The map of every station at 8:00 is in [`docs/img/map_full_at_8.png`](docs/img/map_full_at_8.png).

**Limitations:** one autumn month, about 36 paired readings per hour (bands around 30 points wide), and historical frequency rather than prediction. Details at the end of the notebook.

## Power BI dashboard

![Power BI dashboard](docs/img/powerbi_dashboard.png)

The same results as an interactive Power BI report, built on the dbt marts:

- **Stations most often full:** ranking of stations by % of readings with no free dock, filtered by type of day and hour. At 8:00 on working days it reproduces the notebook's ranking exactly (UPV Junto Pistas Deportivas 67%, station 105 47%).
- **My commute, 74 to 105:** bike at the origin, free dock at the destination and both at once, hour by hour, on working days.
- **Collection health:** clean readings per station and day, where the November outage is visible.
- **Whole-city card:** % of readings with a free dock for the selected type of day and hour, as a reference for the campus figures.

How it is built:

```
dbt marts -> src/export_powerbi.py -> Excel (station_hour, daily, trips, cleaning_log) -> Power BI semantic model -> report
```

- **Why an Excel file:** Power BI Desktop does not run on Mac, and Power BI on the web cannot connect to Supabase directly. The export is aggregated to about 0.5 MB so it uploads to the web version.
- **Counts, not percentages:** the export keeps `readings` and `readings_with_dock` and the percentages are DAX measures, so they stay correct for any filter: `% free dock = DIVIDE(SUM(readings_with_dock), SUM(readings))`, `% full = 1 - [% free dock]`, `% bike available`, `Readings count` and `Readings per station`. Averaging stored percentages would give an hour with 2 readings the same weight as one with 36.
- **Modelling details:** `local_hour` is set not to summarize (an hour is not a quantity) and `local_date` is typed as a date.
- **Checked against the analysis:** a DAX query on the model gives 53% free docks at station 105 at 8:00 on working days over 36 readings, the same as the dbt mart and the notebook.
- **Data snapshot:** the dashboard uses the export of 5 November 2026, the same period as the final analysis, so the figures match the notebook and this README.

## Incident: collection outage, 1-5 November 2026

![Clean readings per station and day](docs/img/collection_health.png)

The GitHub token that `pg_cron` uses to trigger the collection expired on 1 November around 15:00 (Valencia time). From then on GitHub rejected every call with a `401`, and only GitHub's own fallback schedule ran, every 3 to 13 hours.

- **How it was detected:** the dbt test `assert_no_collection_gaps` warned of 13 gaps longer than two hours in the last week, and `dbt source freshness` showed the newest data was hours old.
- **How it was diagnosed:** the responses logged by `pg_net` (`net._http_response`) showed `401` until the fix and `204` right after.
- **Fix:** the token was regenerated and updated in Supabase Vault on 5 November; collection resumed immediately.
- **Impact:** four working days with 2-4 readings per station instead of 48. They are left out of the working-day count, and their few readings are too scattered to bias the results.
- **Lesson:** a credential with an expiry date is a scheduled outage. The token now expires in a year, with a reminder set a week before.

## Design decisions

- **Idempotent loads.** The composite primary key plus `ON CONFLICT DO NOTHING` means the pipeline can run any number of times without creating duplicates. If a station has not sent a new measurement since the last run, nothing is inserted for it.
- **Two timestamps.** `updated_at` (source time) and `fetched_at` (ingestion time) are kept separately, which makes it possible to detect stations that stop reporting.
- **Load order.** Stations are upserted before availability rows so the foreign key is always satisfied, even when a new station appears.
- **Scheduling from the database.** GitHub's built-in `schedule` trigger is best-effort: in its first 28 hours it ran the job 4 times instead of about 56. The workflow is now triggered by a `pg_cron` job that calls GitHub's API every 30 minutes. GitHub's own schedule is kept as a fallback, and idempotent loads make the overlap harmless. The fallback is what kept a few readings coming during the November outage (see above).
- **Raw data is never modified.** Cleaning rules (start date, holidays) live in a view on top of the raw table, so they can change without losing data.
- **No secrets in code.** The connection string lives in a local `.env` file (git-ignored) and in GitHub Secrets for the workflow. The GitHub token used by `pg_cron` is stored encrypted in Supabase Vault.
- **dbt Core v1, not v2.** dbt v2 does not support PostgreSQL, so the project uses the latest stable dbt Core 1.x with the `dbt-postgres` adapter. The project parses with no deprecation warnings, which is the requirement for a future move to v2.
- **Tables, not incremental models.** Rebuilding the marts from scratch takes seconds at this size (a few hundred thousand rows). Incremental models would add complexity with no benefit yet; they become worth it if the history grows to tens of millions of rows.
- **One secret.** dbt needs host, user and password as separate fields; `dbt/db_env.py` splits the existing `DATABASE_URL` instead of adding new secrets, and masks the password in the GitHub Actions logs.
- **Pinned environment.** Dependency versions are pinned in `requirements.txt` and the runner OS is pinned to `ubuntu-24.04` so the environment does not change silently.

## Data quality notes

Observed while exploring the raw data:

- Some stations keep reporting the same `updated_at` for days (e.g. stuck at 0 bikes and 0 docks), so a station can look "empty" when it is actually not reporting. A station that sends nothing new adds no rows, so those hours are missing from its figures rather than counted.
- A station with 0 bikes and 0 free docks is out of service, not full. The SQL view counts it as "no bike and no dock", which is what a rider would find; the notebook excludes those readings to describe the system working normally.
- `is_open` is `True` in every reading, even for stations out of service for weeks, so it cannot be used to detect closures.
- For a share of stations, `bikes + free_docks` is lower than `total_docks`, most likely because of docks out of service.
- Twice in the first four weeks `bikes + free_docks` was **higher** than `total_docks`, which is impossible (stations 112 and 113, off by one, both at the 8:00 arrival peak). The readings are kept, because an error of one does not change whether there was a bike or a free dock; a dbt test warns on every new case and fails if they become frequent.
- The API also publishes station 299 "LABMAD", a test dock in a lab in Madrid (first seen November 2026). Its rows stay in the raw tables; the cleaning drops every station outside Valencia's bounding box, and the coordinate tests warn if a new one appears.
- On 18-19 November the API was slow and some runs retried. `fetched_at` was taken before the download, so 33 readings from one run looked updated after they were fetched. It is now taken after the download; the dbt test warns on any new case and fails only if it becomes frequent. Before this fix, these two issues failed source tests and dbt skipped every downstream model, so the marts stayed frozen at 18 November for five days.
- Measurements are snapshots every 30 minutes. A bike taken and another returned between two snapshots cancel out, so movement is always underestimated.

## Run it locally

Requirements: Python 3.12 and a PostgreSQL database (e.g. a free Supabase project) with the two raw tables above.

```bash
git clone https://github.com/daniv14-hub/valenbisi-pipeline.git
cd valenbisi-pipeline
python -m venv .venv
source .venv/bin/activate
pip install -r requirements.txt

echo "DATABASE_URL=postgresql://user:password@host:5432/postgres" > .env

python src/load.py      # extract + load into the database
python src/extract.py   # optional: only save a raw JSON snapshot to data/raw/
```

Then run `sql/setup.sql` in the database to create the holidays table and the view. `sql/schedule.sql` documents the optional `pg_cron` trigger.

To build and test the dbt layer (from the repo root):

```bash
pip install -r requirements-dbt.txt
eval "$(python dbt/db_env.py)"   # builds dbt's connection settings from DATABASE_URL
cd dbt
dbt deps
dbt build                        # models + 47 data tests
dbt source freshness             # is the collection still running?
```

To run the analysis notebook:

```bash
pip install -r requirements-analysis.txt
```

Then open `notebooks/01_analysis.ipynb` (exploration and cleaning rules) or `notebooks/02_final_analysis.ipynb` (final analysis on the dbt marts, needs `dbt build` first) and run all cells. Charts are saved to `docs/img/`.

To export the marts for the Power BI dashboard (`data/powerbi/valenbisi_powerbi.xlsx`, about 0.5 MB, uploaded to Power BI on the web with *Create > Excel*):

```bash
python src/export_powerbi.py
```

## Roadmap

- [x] Extraction from the open data API with retries
- [x] Load into PostgreSQL (dimension + fact tables, idempotent)
- [x] Runs every 30 minutes (`pg_cron` triggering GitHub Actions)
- [x] Analysis layer: holidays and hourly availability view
- [x] First analysis: data quality checks, cleaning and results (`notebooks/01_analysis.ipynb`)
- [x] Cleaning rules moved to dbt, with 47 automated data tests run daily in GitHub Actions
- [x] Monitoring of the collection: source freshness and run-gap checks (dbt)
- [x] Final analysis with charts and confidence bands (`notebooks/02_final_analysis.ipynb`)
- [x] Power BI dashboard on the dbt marts, with DAX measures
- [ ] Simple page: pick a station to leave from, a station to park at and a time
- [ ] Estimate trip time from the distance between stations
- [ ] Compare weekdays (e.g. is Tuesday worse than Friday?) once there are enough weeks of data
- [ ] Alert when a single station stops reporting (today stale readings are filtered out, not reported)

## Data source

[Valenbisi station availability](https://geoportal.valencia.es/server/rest/services/OPENDATA/Trafico/MapServer/228) — Ajuntament de València open data portal.
