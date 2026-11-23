"""Export the dbt marts to one Excel file for the Power BI dashboard.

Power BI Desktop does not run on Mac, and the web version (app.powerbi.com)
cannot connect to Supabase directly, so the dashboard is built from a file.

Run from the repo root, after `dbt build`:
    python src/export_powerbi.py

Output: data/powerbi/valenbisi_powerbi.xlsx (data/ is git-ignored).

Sheets (small on purpose: about 0.5 MB, so it uploads to Power BI on the web):
- station_hour   fct_station_hourly summed over dates, plus station name,
                 location and capacity: station x type of day x hour.
                 Counts, not percentages, so Power BI aggregates them correctly:
                 % free dock = sum(readings_with_dock) / sum(readings).
- daily          clean readings and stations per day, for the collection
                 health chart.
- trips          mart_trip_success
- cleaning_log   rpt_cleaning_log
"""
import os
from pathlib import Path

import pandas as pd
from dotenv import load_dotenv
from sqlalchemy import create_engine

OUT = Path("data/powerbi/valenbisi_powerbi.xlsx")

QUERIES = {
    "station_hour": """
        SELECT h.station_id, s.station_label, s.latitude, s.longitude, s.capacity,
               h.day_type, h.local_hour,
               sum(h.readings) AS readings,
               sum(h.readings_with_bike) AS readings_with_bike,
               sum(h.readings_with_dock) AS readings_with_dock,
               sum(h.readings_with_dock_margin) AS readings_with_dock_margin
        FROM analytics.fct_station_hourly h
        JOIN analytics.dim_stations s USING (station_id)
        GROUP BY h.station_id, s.station_label, s.latitude, s.longitude, s.capacity,
                 h.day_type, h.local_hour
        ORDER BY h.station_id, h.day_type, h.local_hour
    """,
    "daily": """
        SELECT local_date, day_type,
               sum(readings) AS readings,
               count(DISTINCT station_id) AS stations
        FROM analytics.fct_station_hourly
        GROUP BY local_date, day_type
        ORDER BY local_date
    """,
    "trips": "SELECT * FROM analytics.mart_trip_success ORDER BY origin_id, destination_id, day_type, local_hour",
    "cleaning_log": "SELECT * FROM analytics.rpt_cleaning_log ORDER BY step",
}


def main() -> None:
    load_dotenv()
    url = os.environ["DATABASE_URL"].replace("postgresql://", "postgresql+psycopg://", 1)
    engine = create_engine(url)

    OUT.parent.mkdir(parents=True, exist_ok=True)
    with pd.ExcelWriter(OUT, engine="openpyxl") as writer:
        for sheet, query in QUERIES.items():
            df = pd.read_sql(query, engine)
            df.to_excel(writer, sheet_name=sheet, index=False)
            print(f"{sheet:13} {len(df):>8} rows")

    print(f"Written {OUT} ({OUT.stat().st_size / 1e6:.1f} MB)")


if __name__ == "__main__":
    main()
