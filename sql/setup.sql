-- Valenbisi pipeline: analysis layer (PostgreSQL / Supabase)
--
-- Run this file once in the Supabase SQL Editor, after the `stations` and
-- `availability` tables exist. It is safe to run again: nothing is duplicated.
--
-- The raw `availability` table is never modified. Everything here is built
-- on top of it, so the cleaning rules can change without losing data.


-- 1. Public holidays in Valencia.
--    A holiday on a weekday behaves like a weekend, so it must not be counted
--    as a normal working day. Add new dates here as the calendar is published.
CREATE TABLE IF NOT EXISTS holidays (
    day  DATE PRIMARY KEY,
    name TEXT NOT NULL
);

INSERT INTO holidays (day, name) VALUES
    ('2026-10-09', 'Dia de la Comunitat Valenciana'),
    ('2026-10-12', 'Fiesta Nacional de Espana'),
    ('2026-12-08', 'Inmaculada Concepcion'),
    ('2026-12-25', 'Navidad')
ON CONFLICT (day) DO NOTHING;


-- 2. How often is there a bike to take or a free dock to park?
--    One row per station, type of day and hour of the day (Valencia time).
--
--    pct_bike_available    % of measurements with at least 1 bike
--    pct_dock_available    % of measurements with at least 1 free dock
--    pct_dock_with_margin  % of measurements with at least 3 free docks
--
--    These are historical frequencies, not predictions. Always read them
--    together with `measurements`: a percentage over a handful of rows means little.
--
--    Only data from 2026-10-03 is used. Before that date the pipeline ran
--    every 5-6 hours instead of every 30 minutes.
CREATE OR REPLACE VIEW station_hourly_availability
WITH (security_invoker = true) AS
WITH measurements AS (
    SELECT
        station_id,
        updated_at AT TIME ZONE 'Europe/Madrid' AS local_time,
        bikes,
        free_docks
    FROM availability
    WHERE updated_at >= TIMESTAMPTZ '2026-10-03 00:00:00+02'
)
SELECT
    m.station_id,
    s.name,
    CASE
        WHEN h.day IS NOT NULL THEN 'weekend_or_holiday'
        WHEN EXTRACT(ISODOW FROM m.local_time) >= 6 THEN 'weekend_or_holiday'
        ELSE 'workday'
    END AS day_type,
    EXTRACT(HOUR FROM m.local_time)::INT AS local_hour,
    COUNT(*) AS measurements,
    ROUND(100.0 * SUM(CASE WHEN m.bikes >= 1 THEN 1 ELSE 0 END) / COUNT(*)) AS pct_bike_available,
    ROUND(100.0 * SUM(CASE WHEN m.free_docks >= 1 THEN 1 ELSE 0 END) / COUNT(*)) AS pct_dock_available,
    ROUND(100.0 * SUM(CASE WHEN m.free_docks >= 3 THEN 1 ELSE 0 END) / COUNT(*)) AS pct_dock_with_margin
FROM measurements m
JOIN stations s ON s.station_id = m.station_id
LEFT JOIN holidays h ON h.day = m.local_time::DATE
GROUP BY m.station_id, s.name, day_type, local_hour;
