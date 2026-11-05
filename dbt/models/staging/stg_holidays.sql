select
    day as holiday_date,
    name as holiday_name
from {{ source('valenbisi', 'holidays') }}
