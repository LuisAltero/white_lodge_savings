-- Calendar covering the event period.
--
-- Cheap to build, and it solves a problem that only shows up too late: a day with
-- no claims doesn't exist in `group by filled_date`, so the series gets an
-- invisible hole that reads as a gentle decline. Start from the calendar, left
-- join the fact, and the zero shows up as a zero.
--
-- The spine spans *every* event date, not just fills. It used to be
-- min/max(filled_at) alone — and since `mart_funnel_daily` inner joins this
-- model, a lookup on a day with no claims, or a reversal after the last fill,
-- would have dropped out of the funnel silently. That is the exact failure this
-- table exists to prevent. Here all three streams happen to span 2026-03-01 to
-- 2026-07-31; the union is what stops that coincidence from being load-bearing.

with event_dates as (

    select filled_date as date_day
    from {{ ref('int_claims_scoped') }}
    where scope_exclusion_reason is null

    union all

    select lookup_date
    from {{ ref('int_lookups_resolved') }}

    union all

    select cast(reverted_at as date)
    from {{ ref('int_reverts_scoped') }}
    where scope_exclusion_reason is null

),

bounds as (

    select
        min(date_day) as min_date,
        max(date_day) as max_date
    from event_dates

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
