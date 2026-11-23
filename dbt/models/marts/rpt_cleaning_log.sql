-- How many readings each cleaning rule removes. Rebuilt on every run, so the
-- data quality of the whole dataset can be monitored over time (and shown in
-- the dashboard), not only checked once in the notebook.
with r as (
    select * from {{ ref('stg_availability') }}
),

steps as (
    select 0 as step, 'raw readings' as rule, count(*) as rows_left
    from r
    union all
    select 1, 'from collection start', count(*)
    from r
    where updated_at >= timestamptz '{{ var("collection_start") }}'
    union all
    select 2, 'delay <= {{ var("max_lag_minutes") }} min', count(*)
    from r
    where updated_at >= timestamptz '{{ var("collection_start") }}'
      and lag_minutes <= {{ var("max_lag_minutes") }}
    union all
    select 3, 'in service, in Valencia', count(*)
    from r
    join {{ ref('stg_stations') }} s using (station_id)
    where updated_at >= timestamptz '{{ var("collection_start") }}'
      and lag_minutes <= {{ var("max_lag_minutes") }}
      and not is_out_of_service
      and s.is_in_valencia
    union all
    select 4, 'one reading per slot', count(*)
    from {{ ref('int_readings_clean') }}
)

select
    step,
    rule,
    rows_left,
    coalesce(lag(rows_left) over (order by step) - rows_left, 0) as rows_removed
from steps
order by step
