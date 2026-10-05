# Valenbisi Pipeline
Valenbisi's app shows how many bikes and free docks each station has right now, but not what you will find when you actually get there. This project collects the availability of every station every 30 minutes and uses that history to show, for each station and time of day, how often there was a bike to take or a free dock to park. The goal is to help people in Valencia decide whether a trip by Valenbisi is worth it.

An automated data pipeline that collects real-time availability from **Valenbisi**, the public bike-sharing system in Valencia (Spain), and stores it as a historical dataset in PostgreSQL for later analysis.

Every 30 minutes, a scheduled GitHub Actions job pulls the status of all ~270 stations from the City of Valencia's open data API and loads it into a Supabase (PostgreSQL) database.

## Architecture

```mermaid
flowchart LR
    A[Valencia Open Data API<br/>geoportal.valencia.es] -->|HTTP / JSON| B[extract.py<br/>fetch + retries]
    B --> C[load.py<br/>transform + load]
    C -->|upsert| D[(stations)]
    C -->|insert, skip duplicates| E[(availability)]
    F[GitHub Actions<br/>cron every 30 min] -->|runs| C
```

| Step | What it does |
|------|--------------|
| **Extract** (`src/extract.py`) | Queries the ArcGIS REST endpoint for all stations. Retries up to 3 times with increasing waits and fails loudly if the API returns an error or a truncated response. |
| **Transform + Load** (`src/load.py`) | Splits each record into static station data and a time-stamped availability snapshot, converts types (epoch ms → `TIMESTAMPTZ`, `'T'/'F'` → `BOOLEAN`) and writes both to PostgreSQL in a single transaction. |
| **Orchestration** (`.github/workflows/collect.yml`) | Runs the pipeline every 30 minutes on GitHub-hosted runners. Database credentials are injected from GitHub Secrets. |

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

## Design decisions

- **Idempotent loads.** The composite primary key plus `ON CONFLICT DO NOTHING` means the pipeline can run any number of times without creating duplicates. If a station has not sent a new measurement since the last run, nothing is inserted for it.
- **Two timestamps.** `updated_at` (source time) and `fetched_at` (ingestion time) are kept separately, which makes it possible to detect stations that stop reporting.
- **Load order.** Stations are upserted before availability rows so the foreign key is always satisfied, even when a new station appears.
- **No secrets in code.** The connection string lives in a local `.env` file (git-ignored) and in GitHub Secrets for the scheduled job.
- **Pinned environment.** Dependency versions are pinned in `requirements.txt` and the runner OS is pinned to `ubuntu-24.04` so the environment does not change silently.

## Data quality notes

Observed while exploring the raw data:

- Some stations keep reporting the same `updated_at` for days (e.g. stuck at 0 bikes and 0 docks), so a station can look "empty" when it is actually not reporting.
- For a share of stations, `bikes + free_docks` is lower than `total_docks`, most likely because of docks out of service.

These will be handled in the analysis stage.

## Run it locally

Requirements: Python 3.12 and a PostgreSQL database (e.g. a free Supabase project) with the two tables above.

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

## Roadmap

- [x] Extraction from the open data API with retries
- [x] Load into PostgreSQL (dimension + fact tables, idempotent)
- [x] Scheduled runs with GitHub Actions
- [ ] Analysis: occupancy by hour and weekday, stations that run empty or full
- [ ] Monitoring of stations that stop reporting

## Data source

[Valenbisi station availability](https://geoportal.valencia.es/server/rest/services/OPENDATA/Trafico/MapServer/228) — Ajuntament de València open data portal.
