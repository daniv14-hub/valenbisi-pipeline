-- Grain: station x local date x local hour.
-- Counts instead of percentages, so any tool can aggregate them correctly:
-- % with a dock = sum(readings_with_dock) / sum(readings), never avg of percentages.
-- This is the table the Power BI dashboard uses.
select
    station_id,
    local_date,
    local_hour,
    iso_weekday,
    day_type,
    count(*) as readings,
    count(*) filter (where has_bike) as readings_with_bike,
    count(*) filter (where has_dock) as readings_with_dock,
    count(*) filter (where has_dock_with_margin) as readings_with_dock_margin,
    round(avg(bikes), 1) as avg_bikes,
    round(avg(free_docks), 1) as avg_free_docks
from {{ ref('fct_readings') }}
group by station_id, local_date, local_hour, iso_weekday, day_type
