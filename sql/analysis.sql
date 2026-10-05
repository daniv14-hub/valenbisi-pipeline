-- Valenbisi pipeline: analysis queries (PostgreSQL)
--
-- Part A answers the question the project exists for.
-- Part B is the exploration that led there: what the data looks like and
-- which stations behave oddly.
--
-- Timestamps are stored in UTC and converted to Europe/Madrid for reading.
-- Reliable 30-minute data starts on 2026-10-03; earlier days have gaps.
-- Part A needs the view created in sql/setup.sql.


-- ============================================================
-- PART A. Is a trip by Valenbisi worth it?
-- ============================================================

-- A1. Availability profile of one station, hour by hour.
--     Example: station 105 (Avda. de los Naranjos, next to the UPV campus).
SELECT
    day_type,
    local_hour,
    measurements,
    pct_bike_available,
    pct_dock_available,
    pct_dock_with_margin
FROM station_hourly_availability
WHERE station_id = 105
ORDER BY day_type, local_hour;


-- A2. Checking one trip: take a bike at one station, park it at another.
--     Example: leave station 148 at 8:00 on a working day and park at station 105 at 9:00.
--     Read pct_bike_available on the first row and the two dock columns on the second.
SELECT
    name,
    local_hour,
    measurements,
    pct_bike_available,
    pct_dock_available,
    pct_dock_with_margin
FROM station_hourly_availability
WHERE day_type = 'workday'
  AND ((station_id = 148 AND local_hour = 8)
    OR (station_id = 105 AND local_hour = 9))
ORDER BY local_hour;


-- A3. Where is it hardest to park at 8:00 on a working day? (top 10)
--     Stations with fewer than 10 measurements are left out: too few to trust.
SELECT
    name,
    measurements,
    pct_dock_available,
    pct_dock_with_margin
FROM station_hourly_availability
WHERE day_type = 'workday'
  AND local_hour = 8
  AND measurements >= 10
ORDER BY pct_dock_available, pct_dock_with_margin
LIMIT 10;


-- ============================================================
-- PART B. Exploration
-- ============================================================

-- B1. How much data is collected per day?
--     One pipeline run = one distinct fetched_at.
SELECT
    DATE(fetched_at AT TIME ZONE 'Europe/Madrid') AS local_day,
    COUNT(DISTINCT fetched_at) AS runs,
    COUNT(*) AS row_count
FROM availability
GROUP BY local_day
ORDER BY local_day;


-- B2. Average bikes available per station, by hour of the day.
--     Fewer bikes docked = more bikes in use.
SELECT
    EXTRACT(HOUR FROM updated_at AT TIME ZONE 'Europe/Madrid') AS local_hour,
    ROUND(AVG(bikes), 1) AS avg_bikes
FROM availability
WHERE updated_at >= '2026-10-03'
GROUP BY local_hour
ORDER BY local_hour;


-- B3. Which stations are empty most often? (top 10)
--     Share of measurements with zero bikes.
SELECT
    s.name,
    COUNT(*) AS measurements,
    ROUND(100.0 * SUM(CASE WHEN a.bikes = 0 THEN 1 ELSE 0 END) / COUNT(*), 1) AS pct_empty
FROM availability a
JOIN stations s ON s.station_id = a.station_id
WHERE a.updated_at >= '2026-10-03'
GROUP BY s.name
HAVING COUNT(*) >= 50
ORDER BY pct_empty DESC
LIMIT 10;


-- B4. Which stations are full most often? (top 10)
--     "Full" means no free docks while there are bikes. A station with
--     0 bikes and 0 free docks is out of service, not full.
SELECT
    s.name,
    COUNT(*) AS measurements,
    ROUND(100.0 * SUM(CASE WHEN a.free_docks = 0 AND a.bikes > 0 THEN 1 ELSE 0 END) / COUNT(*), 1) AS pct_full
FROM availability a
JOIN stations s ON s.station_id = a.station_id
WHERE a.updated_at >= '2026-10-03'
GROUP BY s.name
HAVING COUNT(*) >= 50
ORDER BY pct_full DESC
LIMIT 10;


-- B5. Drill-down on one station: is it really empty or out of service?
--     If free_docks is close to total_docks, the docks work and the station is just empty.
SELECT
    updated_at AT TIME ZONE 'Europe/Madrid' AS local_time,
    is_open,
    bikes,
    free_docks,
    total_docks
FROM availability
WHERE station_id = 105
  AND updated_at >= '2026-10-03'
ORDER BY updated_at;


-- B6. Movement at one station: change in bikes between consecutive measurements.
--     LAG brings the value of the previous row. Negative = bikes taken, positive = bikes returned.
SELECT
    updated_at AT TIME ZONE 'Europe/Madrid' AS local_time,
    bikes,
    LAG(bikes) OVER (ORDER BY updated_at) AS previous_bikes,
    bikes - LAG(bikes) OVER (ORDER BY updated_at) AS change
FROM availability
WHERE station_id = 194
  AND updated_at >= '2026-10-03'
ORDER BY updated_at;


-- B7. Which stations have the most movement? (top 10)
--     Sum of absolute changes per station. This is a lower bound: a bike taken
--     and another returned between two measurements cancel out.
WITH changes AS (
    SELECT
        station_id,
        bikes - LAG(bikes) OVER (PARTITION BY station_id ORDER BY updated_at) AS change
    FROM availability
    WHERE updated_at >= '2026-10-03'
)
SELECT
    s.name,
    SUM(ABS(c.change)) AS movement
FROM changes c
JOIN stations s ON s.station_id = c.station_id
GROUP BY s.name
ORDER BY movement DESC NULLS LAST
LIMIT 10;
