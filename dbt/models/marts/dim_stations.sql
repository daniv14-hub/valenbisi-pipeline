-- One row per station. Capacity is taken from the most recent reading,
-- because it is reported with each measurement, not with the station.
with latest_capacity as (
    select distinct on (station_id)
        station_id,
        total_docks as capacity
    from {{ ref('stg_availability') }}
    order by station_id, updated_at desc
)

select
    s.station_id,
    s.station_name,
    -- Several stations share a name (four "Avda. De Los Naranjos"),
    -- so charts use this label to tell them apart
    s.station_name || ' (' || s.station_id || ')' as station_label,
    s.raw_name,
    s.address,
    s.latitude,
    s.longitude,
    c.capacity
from {{ ref('stg_stations') }} s
left join latest_capacity c using (station_id)
