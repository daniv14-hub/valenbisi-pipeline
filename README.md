# Valenbisi Pipeline

Valenbisi's app shows how many bikes and free docks each station has right now, but not what you will find when you actually get there. This project collects the availability of every station every 30 minutes and uses that history to show, for each station and time of day, how often there was a bike to take or a free dock to park. The goal is to help people in Valencia decide whether a trip by Valenbisi is worth it.

An automated data pipeline that collects real-time availability from **Valenbisi**, the public bike-sharing system in Valencia (Spain), and stores it as a historical dataset in PostgreSQL for later analysis.

Every 30 minutes, a GitHub Actions job pulls the status of all ~270 stations from the City of Valencia's open data API and loads it into a Supabase (PostgreSQL) database. The job is triggered from the database itself with `pg_cron`.

## Architecture

```mermaid
flowchart LR
    G[Supabase pg_cron<br/>every 30 min] -->|workflow dispatch| F[GitHub Actions<br/>collect.yml]
    F -->|runs| C
    A[Valencia Open Data API<br/>geoportal.valencia.es] -->|HTTP / JSON| B[extract.py<br/>fetch + retries]
    B --> C[load.py<br/>transform + load]
    C -->|upsert| D[(stations)]
    C -->|insert, skip duplicates| E[(availability)]
    D --> V[station_hourly_availability<br/>view]
    E --> V
```

| Step | What it does |
|------|--------------|
| **Extract** (`src/extract.py`) | Queries the ArcGIS REST endpoint for all stations. Retries up to 3 times with increasing waits and fails loudly if the API returns an error or a truncated response. |
| **Transform + Load** (`src/load.py`) | Splits each record into static station data and a time-stamped availability snapshot, converts types (epoch ms → `TIMESTAMPTZ`, `'T'/'F'` → `BOOLEAN`) and writes both to PostgreSQL in a single transaction. |
| **Orchestration** (`.github/workflows/collect.yml`) | Runs the pipeline on GitHub-hosted runners. Database credentials are injected from GitHub Secrets. |
| **Scheduling** (`sql/schedule.sql`) | A `pg_cron` job in Supabase calls GitHub's workflow dispatch API every 30 minutes through `pg_net`. |
| **Analysis layer** (`sql/setup.sql`) | A holidays table and a view that turns the raw measurements into availability percentages per station, type of day and hour. |

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

## Using the data

The view answers the question the project exists for. For example, how easy is it to park at station 105 (next to the UPV campus) on a working day, hour by hour:

```sql
SELECT local_hour, measurements, pct_bike_available, pct_dock_available, pct_dock_with_margin
FROM station_hourly_availability
WHERE station_id = 105
  AND day_type = 'workday'
ORDER BY local_hour;
```

More queries, including the exploration that led to this design, are in [`sql/analysis.sql`](sql/analysis.sql).

How to read the numbers:

- They are **historical frequencies, not predictions**: "on working days at 9:00 this station had a free dock in X% of the measurements".
- The view is computed over all the data collected so far, so the figures get more reliable every week. Always check `measurements`: a percentage over a handful of rows means little.
- Collection every 30 minutes started on 3 October 2026. Earlier rows are kept in the raw table but left out of the view.

## Design decisions

- **Idempotent loads.** The composite primary key plus `ON CONFLICT DO NOTHING` means the pipeline can run any number of times without creating duplicates. If a station has not sent a new measurement since the last run, nothing is inserted for it.
- **Two timestamps.** `updated_at` (source time) and `fetched_at` (ingestion time) are kept separately, which makes it possible to detect stations that stop reporting.
- **Load order.** Stations are upserted before availability rows so the foreign key is always satisfied, even when a new station appears.
- **Scheduling from the database.** GitHub's built-in `schedule` trigger is best-effort: in its first 28 hours it ran the job 4 times instead of about 56. The workflow is now triggered by a `pg_cron` job that calls GitHub's API every 30 minutes. GitHub's own schedule is kept as a fallback, and idempotent loads make the overlap harmless.
- **Raw data is never modified.** Cleaning rules (start date, holidays) live in a view on top of the raw table, so they can change without losing data.
- **No secrets in code.** The connection string lives in a local `.env` file (git-ignored) and in GitHub Secrets for the workflow. The GitHub token used by `pg_cron` is stored encrypted in Supabase Vault.
- **Pinned environment.** Dependency versions are pinned in `requirements.txt` and the runner OS is pinned to `ubuntu-24.04` so the environment does not change silently.

## Data quality notes

Observed while exploring the raw data:

- Some stations keep reporting the same `updated_at` for days (e.g. stuck at 0 bikes and 0 docks), so a station can look "empty" when it is actually not reporting. A station that sends nothing new adds no rows, so those hours are missing from its figures rather than counted.
- A station with 0 bikes and 0 free docks is out of service, not full. In the view it counts as "no bike and no dock", which is what a rider would find.
- For a share of stations, `bikes + free_docks` is lower than `total_docks`, most likely because of docks out of service.
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

## Roadmap

- [x] Extraction from the open data API with retries
- [x] Load into PostgreSQL (dimension + fact tables, idempotent)
- [x] Runs every 30 minutes (`pg_cron` triggering GitHub Actions)
- [x] Analysis layer: holidays and hourly availability view
- [ ] Results after several weeks of data: working days vs weekends and holidays
- [ ] Simple page: pick a station to leave from, a station to park at and a time
- [ ] Estimate trip time from the distance between stations
- [ ] Monitoring of stations that stop reporting

## Data source

[Valenbisi station availability](https://geoportal.valencia.es/server/rest/services/OPENDATA/Trafico/MapServer/228) — Ajuntament de València open data portal.
