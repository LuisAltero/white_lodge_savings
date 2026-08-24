-- Calendar covering the event period.
--
-- Cheap to build, and it solves the problem that only shows up once it's too
-- late: a day with no claims simply doesn't exist in `group by filled_date`, and
-- the time series gets an invisible hole that reads as a gentle decline. Start
-- from the calendar and left join the fact, and the zero shows up as a zero.

with bounds as (

    select
        min(cast(filled_at as date)) as min_date,
        max(cast(filled_at as date)) as max_date
    from {{ ref('stg_claims') }}
    where dq_reject_reason is null

),

spine as (

    select unnest(generate_series(
        (select min_date from bounds),
        (select max_date from bounds),
        interval 1 day
    )) as date_day

)

select
    cast(date_day as date)              as date_day,
    year(date_day)                      as year,
    month(date_day)                     as month,
    date_trunc('month', date_day)::date as month_start,
    date_trunc('week', date_day)::date  as week_start,
    dayofweek(date_day)                 as day_of_week,
    dayname(date_day)                   as day_name,
    dayofweek(date_day) in (0, 6)       as is_weekend
from spine
