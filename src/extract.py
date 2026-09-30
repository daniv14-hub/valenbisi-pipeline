import json
from datetime import datetime, timezone
from pathlib import Path
import requests
import time

MAX_ATTEMPTS = 3

URL = "https://geoportal.valencia.es/server/rest/services/OPENDATA/Trafico/MapServer/228/query"

PARAMS = {
    "where": "1=1",
    "outFields": "number,name,address,open,available,free,total,update_jcd",
    "outSR": 4326,
    "f": "json",
}

def fetch_stations() -> list[dict]:
    for attempt in range(1, MAX_ATTEMPTS + 1):
        try:
            response = requests.get(URL, params=PARAMS, timeout=60)
            response.raise_for_status()
            break
        except requests.RequestException as error:
            if attempt == MAX_ATTEMPTS:
                raise
            wait = 10 * attempt
            print(f"Attempt {attempt} failed: {error}. Retrying in {wait}s...")
            time.sleep(wait)

    data = response.json()

    if "error" in data:
        raise RuntimeError(f"API error: {data['error']}")
    if data.get("exceededTransferLimit"):
        raise RuntimeError("The API did not return all stations")

    return data["features"]

def main() -> None:
    fetched_at = datetime.now(timezone.utc)
    features = fetch_stations()
    print(f"{len(features)} stations fetched at {fetched_at.isoformat()}")

    out_file = Path("data/raw") / f"valenbisi_{fetched_at:%Y%m%dT%H%M%SZ}.json"
    out_file.parent.mkdir(parents=True, exist_ok=True)
    out_file.write_text(json.dumps(features, ensure_ascii=False, indent=2))
    print(f"Saved to {out_file}")

if __name__ == "__main__":
    main()
