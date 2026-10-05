-- Valenbisi pipeline: exploratory analysis queries (PostgreSQL)
-- Timestamps are stored in UTC and converted to Europe/Madrid for reading.
-- Reliable 30-minute data starts on 2026-10-03; earlier days have gaps.


-- 1. How much data is collected per day?
--    One pipeline run = one distinct fetched_at.
SELECT
    DATE(fetched_at AT TIME ZONE 'Europe/Madrid') AS local_day,
    COUNT(DISTINCT fetched_at) AS runs,
    COUNT(*) AS row_count
FROM availability
GROUP BY local_day
ORDER BY local_day;


-- 2. Average bikes available per station, by hour of the day.
--    Fewer bikes docked = more bikes in use.
SELECT
    EXTRACT(HOUR FROM updated_at AT TIME ZONE 'Europe/Madrid') AS local_hour,
    ROUND(AVG(bikes), 1) AS avg_bikes
FROM availability
WHERE updated_at >= '2026-10-03'
GROUP BY local_hour
ORDER BY local_hour;


-- 3. Which stations are empty most often?
--    Share of measurements with zero bikes, per station (top 10).
SELECT
    s.name,
    COUNT(*) AS measurements,
    ROUND(100.0 * SUM(CASE WHEN a.bikes = 0 THEN 1 ELSE 0 END) / COUNT(*), 1) AS pct_empty
FROM availability a
JOIN stations s ON s.station_id = a.station_id
WHERE a.updated_at >= '2026-10-03'
GROUP BY s.name
ORDER BY pct_empty DESC
LIMIT 10;


-- 4. Drill-down on one station: is it really empty or out of service?
--    If free_docks is close to total_docks, the docks work and the station is just empty.
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
