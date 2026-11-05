-- The project's question for one station, answered in SQL:
-- on this type of day and hour, how often was there a bike / a free dock?
-- Historical frequencies, not predictions. Read them with `readings`.
select
    p.station_id,
    s.station_label,
    p.day_type,
    p.local_hour,
    sum(p.readings) as readings,
    round(100.0 * sum(p.readings_with_bike) / sum(p.readings), 1) as pct_bike,
    round(100.0 * sum(p.readings_with_dock) / sum(p.readings), 1) as pct_dock,
    round(100.0 * sum(p.readings_with_dock_margin) / sum(p.readings), 1) as pct_dock_with_margin
from {{ ref('fct_station_hourly') }} p
join {{ ref('dim_stations') }} s using (station_id)
group by p.station_id, s.station_label, p.day_type, p.local_hour
