-- Does a trip work? A bike at the origin AND a free dock at the destination.
-- Readings of both stations are paired in the same 30-minute slot (the ride
-- takes a few minutes). Multiplying the two separate probabilities would
-- assume the stations are independent; pct_naive shows how far off that is.
-- Trips are listed in dbt_project.yml (var `trips`).

with readings as (
    select * from {{ ref('fct_readings') }}
),

pairs as (
    {% for trip in var('trips') %}
    select
        o.station_id as origin_id,
        d.station_id as destination_id,
        o.day_type,
        o.local_hour,
        o.has_bike as bike_ok,
        d.has_dock as dock_ok
    from readings o
    join readings d
        on d.slot_start = o.slot_start
       and d.station_id = {{ trip.destination }}
    where o.station_id = {{ trip.origin }}
    {% if not loop.last %}union all{% endif %}
    {% endfor %}
),

summary as (
    select
        origin_id,
        destination_id,
        day_type,
        local_hour,
        count(*) as paired_readings,
        avg(bike_ok::int) as p_bike,
        avg(dock_ok::int) as p_dock,
        avg((bike_ok and dock_ok)::int) as p_trip
    from pairs
    group by origin_id, destination_id, day_type, local_hour
)

select
    s.origin_id,
    o.station_label as origin_label,
    s.destination_id,
    d.station_label as destination_label,
    s.day_type,
    s.local_hour,
    s.paired_readings,
    round(100 * s.p_bike, 1) as pct_bike_at_origin,
    round(100 * s.p_dock, 1) as pct_dock_at_destination,
    round(100 * s.p_bike * s.p_dock, 1) as pct_naive,
    round(100 * s.p_trip, 1) as pct_trip
from summary s
join {{ ref('dim_stations') }} o on o.station_id = s.origin_id
join {{ ref('dim_stations') }} d on d.station_id = s.destination_id
