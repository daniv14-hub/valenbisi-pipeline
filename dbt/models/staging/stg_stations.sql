-- Station names come as "105_AVDA. DE LOS NARANJOS": drop the number
-- prefix and the underscores, and use title case for charts.
select
    station_id,
    name as raw_name,
    initcap(trim(replace(regexp_replace(name, '^\d+_', ''), '_', ' '))) as station_name,
    address,
    latitude,
    longitude,
    -- False for test docks the API publishes outside the city (station 299, Madrid)
    (latitude between 39.3 and 39.6 and longitude between -0.5 and -0.2) as is_in_valencia
from {{ source('valenbisi', 'stations') }}
