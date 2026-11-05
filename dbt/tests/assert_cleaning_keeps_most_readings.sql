-- A cleaning rule that suddenly removes most of the data is a bug, not a
-- cleaner dataset. The notebook kept 87% of readings; below 75% something
-- changed in the source or in the rules. Returns a row (= fails) if so.
with log as (
    select * from {{ ref('rpt_cleaning_log') }}
)

select
    s1.rows_left as after_start,
    s4.rows_left as after_cleaning
from log s1
cross join log s4
where s1.step = 1
  and s4.step = 4
  and s4.rows_left < 0.75 * s1.rows_left
