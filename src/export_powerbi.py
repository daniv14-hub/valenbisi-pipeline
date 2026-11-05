"""Export the dbt marts to one Excel file for the Power BI dashboard.

Power BI Desktop does not run on Mac, and the web version (app.powerbi.com)
cannot connect to Supabase directly, so the dashboard is built from a file.

Run from the repo root, after `dbt build`:
    python src/export_powerbi.py

Output: data/powerbi/valenbisi_powerbi.xlsx (data/ is git-ignored).

Sheets:
- hourly         fct_station_hourly + station name, location and capacity.
                 One flat table, so the dashboard needs no relationships.
                 Aggregate as sum(readings_with_dock) / sum(readings).
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
    "hourly": """
        SELECT h.*, s.station_name, s.station_label, s.latitude, s.longitude, s.capacity
        FROM analytics.fct_station_hourly h
        JOIN analytics.dim_stations s USING (station_id)
        ORDER BY h.station_id, h.local_date, h.local_hour
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
