-- Grain: one clean reading per station and 30-minute slot.
-- Adds local time, type of day and the three yes/no conditions a rider cares about.
with readings as (
    select
        *,
        updated_at at time zone '{{ var("local_timezone") }}' as local_time
    from {{ ref('int_readings_clean') }}
),

holidays as (
    select * from {{ ref('stg_holidays') }}
)

select
    r.station_id,
    r.slot_start,
    r.updated_at,
    r.local_time,
    r.local_time::date as local_date,
    extract(hour from r.local_time)::int as local_hour,
    extract(isodow from r.local_time)::int as iso_weekday,   -- 1 = Monday ... 7 = Sunday
    case
        when h.holiday_date is not null then 'weekend_or_holiday'
        when extract(isodow from r.local_time) >= 6 then 'weekend_or_holiday'
        else 'workday'
    end as day_type,
    r.bikes,
    r.free_docks,
    r.total_docks,
    r.bikes >= 1 as has_bike,
    r.free_docks >= 1 as has_dock,
    r.free_docks >= 3 as has_dock_with_margin
from readings r
left join holidays h on h.holiday_date = r.local_time::date
