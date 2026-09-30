import os
import psycopg
from dotenv import load_dotenv
from extract import fetch_stations

UPSERT_STATIONS = """
    INSERT INTO stations (station_id, name, address, latitude, longitude)
    VALUES (%s, %s, %s, %s, %s)
    ON CONFLICT (station_id) DO UPDATE SET
        name      = EXCLUDED.name,
        address   = EXCLUDED.address,
        latitude  = EXCLUDED.latitude,
        longitude = EXCLUDED.longitude;
"""

def main() -> None:
    load_dotenv()
    features = fetch_stations()

    rows = []
    for feature in features:
        attrs = feature["attributes"]
        geom = feature["geometry"]
        rows.append((
            attrs["number"],
            attrs["name"],
            attrs["address"],
            geom["y"],
            geom["x"],
        ))

    with psycopg.connect(os.environ["DATABASE_URL"]) as conn:
        with conn.cursor() as cur:
            cur.executemany(UPSERT_STATIONS, rows)

    print(f"{len(rows)} stations loaded into the database")


if __name__ == "__main__":
    main()
