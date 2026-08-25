-- Commercial terms per partner. Two normalisations that matter:
--
-- 1. `fee_percentage` arrives on a 0-100 scale (Hudi 50.0, Flink 80.0) and
--    becomes a 0-1 rate here, once, so no downstream model has to remember to
--    divide by 100.
-- 2. `fee_cents = 0` is a real value — Airflow Rx is a zero-commission partner —
--    not "missing". Hence `is not null` rather than truthiness: a naive check
--    would treat that zero as a percentage partner and pick the wrong fee rule.

with source as (

    select * from {{ source('raw', 'partners') }}

),

cleaned as (

    select
        nullif(trim(partner), '')                            as partner,
        try_cast(nullif(trim(fee_cents), '') as bigint)       as fee_cents,
        try_cast(nullif(trim(fee_percentage), '') as double)  as fee_percentage_raw,
        _source_file
    from source
    where nullif(trim(partner), '') is not null

)

select
    partner,
    fee_cents                   as flat_fee_cents,
    fee_percentage_raw / 100.0  as fee_rate,
    case
        when fee_cents is not null then 'flat'
        when fee_percentage_raw is not null then 'percentage'
        else 'unknown'
    end as fee_model,
    _source_file
from cleaned
