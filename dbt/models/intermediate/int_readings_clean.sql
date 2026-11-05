-- The four cleaning rules from notebooks/01_analysis.ipynb, section 3,
-- applied in the same order. The raw table is never modified.

with readings as (
    select * from {{ ref('stg_availability') }}
),

-- Rule 1: before this date the pipeline ran every few hours, not every 30 minutes
reliable_period as (
    select * from readings
    where updated_at >= timestamptz '{{ var("collection_start") }}'
),

-- Rule 2: the station stopped reporting, so the values are stale
fresh as (
    select * from reliable_period
    where lag_minutes <= {{ var("max_lag_minutes") }}
),

-- Rule 3: 0 bikes and 0 free docks = out of service (is_open cannot be trusted)
in_service as (
    select * from fresh
    where not is_out_of_service
),

-- Rule 4: extra pipeline runs leave 2 readings in some slots; keep the latest
ranked as (
    select
        *,
        row_number() over (
            partition by station_id, slot_start
            order by updated_at desc
        ) as rank_in_slot
    from in_service
)

select
    station_id,
    slot_start,
    updated_at,
    fetched_at,
    bikes,
    free_docks,
    total_docks,
    lag_minutes
from ranked
where rank_in_slot = 1
