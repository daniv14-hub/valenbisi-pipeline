import json
from datetime import datetime, timezone
from pathlib import Path
import requests

URL = "https://geoportal.valencia.es/server/rest/services/OPENDATA/Trafico/MapServer/228/query"

PARAMS = {
    "where": "1=1",
    "outFields": "number,name,address,open,available,free,total,update_jcd",
    "outSR": 4326,
    "f": "json",
}

def fetch_stations() -> list[dict]:
    response = requests.get(URL, params=PARAMS, timeout=30)
    response.raise_for_status()
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
