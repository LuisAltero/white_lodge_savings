-- Lookups that survived staging, with conversion resolved against the analysable
-- claim universe.
--
-- **Resolution, never exclusion.** A lookup is never dropped for pointing at a
-- claim we can't analyse: it is a real event at the top of the funnel, and
-- removing it would shrink the denominator and inflate everybody's conversion
-- rate. What gets removed is the *claim link*, not the row.
--
-- 1,480 lookups carry a claim_id that resolves to nothing — the claim never
-- landed, or was rejected, or is out of scope. `has_unresolvable_claim_id`
-- preserves the fact that a conversion was *claimed*, so the gap stays measurable
-- instead of becoming a NULL that reads as "never converted". Without this,
-- `count(claim_id)` here and `count(*)` in `fct_claim` would disagree and nobody
-- would know which to trust.
--
-- It used to live in `stg_lookups`, which needed `ref('stg_claims')` — that tied
-- the funnel's denominator to the data-quality policy, so changing what gets
-- quarantined moved every partner's conversion rate invisibly. One layer up, the
-- dependency is visible in the DAG.

with lookups as (

    select * from {{ ref('stg_lookups') }}
    where dq_reject_reason is null

),

analysable_claims as (

    select claim_id
    from {{ ref('int_claims_scoped') }}
    where scope_exclusion_reason is null

),

resolved as (

    select
        l.*,
        c.claim_id is not null as claim_is_known
    from lookups as l
    left join analysable_claims as c using (claim_id)

)

select
    lookup_id,
    ndc,
    partner,
    channel,
    looked_up_at,
    lookup_date,

    -- The claim_id survives only if it points at a claim in our universe.
    case when claim_is_known then claim_id end  as claim_id,
    claim_id is not null and not claim_is_known as has_unresolvable_claim_id,
    claim_is_known                              as converted,

    partner_was_missing,
    timestamp_raw,
    _source_file

from resolved
