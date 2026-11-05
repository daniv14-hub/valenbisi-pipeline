-- Station names come as "105_AVDA. DE LOS NARANJOS": drop the number
-- prefix and the underscores, and use title case for charts.
select
    station_id,
    name as raw_name,
    initcap(trim(replace(regexp_replace(name, '^\d+_', ''), '_', ' '))) as station_name,
    address,
    latitude,
    longitude
from {{ source('valenbisi', 'stations') }}
