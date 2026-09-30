import os
from datetime import datetime, timezone  # NUEVO
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

# si ya existe esa estación con ese updated_at, no hace nada
INSERT_AVAILABILITY = """
    INSERT INTO availability
        (station_id, updated_at, fetched_at, is_open, bikes, free_docks, total_docks)
    VALUES (%s, %s, %s, %s, %s, %s, %s)
    ON CONFLICT (station_id, updated_at) DO NOTHING;
"""

def main() -> None:
    load_dotenv()
    fetched_at = datetime.now(timezone.utc)  
    features = fetch_stations()

    station_rows = []
    availability_rows = []  
    for feature in features:
        attrs = feature["attributes"]
        geom = feature["geometry"]

        station_rows.append((
            attrs["number"],
            attrs["name"],
            attrs["address"],
            geom["y"],
            geom["x"],
        ))

        # una fila de disponibilidad por estación
        availability_rows.append((
            attrs["number"],
            datetime.fromtimestamp(attrs["update_jcd"] / 1000, tz=timezone.utc),
            fetched_at,
            attrs["open"] == "T",
            attrs["available"],
            attrs["free"],
            attrs["total"],
        ))

    with psycopg.connect(os.environ["DATABASE_URL"]) as conn:
        with conn.cursor() as cur:
            cur.executemany(UPSERT_STATIONS, station_rows)          # 1º estaciones
            cur.executemany(INSERT_AVAILABILITY, availability_rows)  # 2º disponibilidad

    print(f"{len(station_rows)} stations upserted, {len(availability_rows)} availability rows processed")


if __name__ == "__main__":
    main()