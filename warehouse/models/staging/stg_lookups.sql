-- Price lookups — the top of the funnel. 177k events, the largest source here.
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

),

with_claim as (

    select
        l.*,
        c.claim_id is not null as claim_is_known
    from parsed as l
    left join (
        select claim_id from {{ ref('stg_claims') }} where dq_reject_reason is null
    ) as c using (claim_id)

)

select
    lookup_id,
    ndc,
    coalesce(partner, 'unknown') as partner,
    coalesce(channel, 'unknown') as channel,
    looked_up_at,
    cast(looked_up_at as date) as lookup_date,

    -- The claim_id survives only if it points at a claim that exists in our
    -- universe (897 lookups point at claims that are absent or themselves
    -- rejected). Without this, `count(claim_id)` in the funnel and `count(*)` in
    -- fct_claim would disagree and nobody would know which one to trust. The
    -- flag preserves the fact that a conversion was *claimed*.
    case when claim_is_known then claim_id end  as claim_id,
    claim_id is not null and not claim_is_known as has_unresolvable_claim_id,
    claim_is_known                              as converted,

    partner is null as partner_was_missing,
    timestamp_raw,
    _source_file,

    case
        when lookup_id is null or ndc is null or timestamp_raw is null
            then 'missing_required_field'
        when looked_up_at is null
            then 'unparseable_timestamp'
    end as dq_reject_reason

from with_claim
