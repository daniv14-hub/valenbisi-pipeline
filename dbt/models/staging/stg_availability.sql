-- One row per raw reading, with the fields every later model needs.
-- Nothing is filtered here: staging only renames, types and derives.
select
    station_id,
    updated_at,
    fetched_at,
    is_open,
    bikes,
    free_docks,
    total_docks,

    -- How old the reading was when the pipeline downloaded it
    extract(epoch from (fetched_at - updated_at)) / 60.0 as lag_minutes,

    -- 30-minute slot the reading belongs to. Computed in UTC: Spain's offset
    -- is whole hours, so the slots are the same in local time.
    date_bin(interval '30 minutes', updated_at, timestamptz '2000-01-01 00:00:00+00') as slot_start,

    -- Nothing to take and nowhere to park: the station is out of service
    (bikes + free_docks = 0) as is_out_of_service

from {{ source('valenbisi', 'availability') }}
