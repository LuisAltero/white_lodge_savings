-- Lookups that survived staging, with their conversion resolved against the
-- analysable claim universe.
--
-- ## Why resolution is not exclusion
--
-- A lookup is never excluded for pointing at a claim we can't analyse. It is a
-- real event that really happened at the top of the funnel, and dropping it
-- would shrink the denominator and inflate everybody's conversion rate. What
-- gets removed is the *claim link*, not the row.
--
-- 1,480 lookups carry a claim_id that resolves to nothing — the claim never
-- landed, or was rejected as malformed, or excluded as out of scope. Without
-- this model, `count(claim_id)` in the funnel and `count(*)` in `fct_claim`
-- would disagree and nobody would know which one to trust.
--
-- `has_unresolvable_claim_id` preserves the fact that a conversion was
-- *claimed*, so the discrepancy stays measurable instead of becoming a NULL that
-- looks like "never converted".
--
-- ## Why it isn't in stg_lookups any more
--
-- It needed `ref('stg_claims')`, which made the staging layer a chain and tied
-- the funnel's denominator to the data-quality policy: change what gets
-- quarantined, and every partner's conversion rate moves, invisibly. One layer
-- up, the dependency is explicit in the DAG.

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
