-- Warns if, in the last 7 days, the pipeline went more than 2 hours without
-- a run (one run = one distinct fetched_at). Gaps already happened when the
-- Valenbisi API failed, so this is a warning to look at, not an error.
{{ config(severity='warn') }}

with runs as (
    select distinct fetched_at
    from {{ source('valenbisi', 'availability') }}
    where fetched_at >= now() - interval '7 days'
),

gaps as (
    select
        fetched_at,
        fetched_at - lag(fetched_at) over (order by fetched_at) as gap
    from runs
)

select fetched_at, gap
from gaps
where gap > interval '2 hours'
