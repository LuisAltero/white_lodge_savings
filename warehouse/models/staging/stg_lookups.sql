-- Price lookups — the top of the funnel. 177k events, the largest source here.
-- Source-local: typing and normalisation only, no `ref()` to another model.
--
-- Two policy choices, and neither of them is dropping the row:
--
-- 1. **Missing partner (886 rows) becomes `unknown`, not a rejection.**
--    Checked before deciding: none of those 886 converted. They are real lookup
--    events that merely lost their commercial attribution. Dropping them would
--    shrink the funnel denominator and inflate everyone else's conversion rate
--    — trading incomplete data for a wrong number.
--
-- 2. **Channel is normalised, not validated.** The brief describes `channel` as
--    "e.g. integration, website" — the list is open. `fax`, `phone` and `APP`
--    are legitimate low-volume channels; `APP` is just uppercase. We lowercase,
--    and send empty to `unknown`. Rejecting on unknown channel would be staging
--    deciding which lines of business exist.
--
-- `claim_id` comes out here exactly as it arrived. Deciding whether it points at
-- a claim we can actually analyse needs the claim universe, so that resolution
-- — and the `converted` flag that comes with it — lives in
-- `int_lookups_resolved`.

with source as (

    select * from {{ source('raw', 'lookups') }}

),

parsed as (

    select
        nullif(trim(id), '')             as lookup_id,
        nullif(trim(claim_id), '')       as claim_id,
        nullif(trim(ndc), '')            as ndc,
        nullif(trim(partner), '')        as partner,
        lower(nullif(trim(channel), '')) as channel,
        try_cast("timestamp" as timestamp) as looked_up_at,
        "timestamp" as timestamp_raw,
        _source_file
    from source

)

select
    lookup_id,
    claim_id,
    ndc,
    coalesce(partner, 'unknown') as partner,
    coalesce(channel, 'unknown') as channel,
    looked_up_at,
    cast(looked_up_at as date) as lookup_date,

    partner is null as partner_was_missing,
    timestamp_raw,
    _source_file,

    case
        when lookup_id is null or ndc is null or timestamp_raw is null
            then 'missing_required_field'
        when looked_up_at is null
            then 'unparseable_timestamp'
    end as dq_reject_reason

from parsed
