-- Reversals that survived staging, resolved against the analysable claim universe.
--
-- `orphan_claim_id` (53 rows): the reversal arrived but the claim it invalidates
-- isn't in our universe — it never landed, or was itself rejected or excluded.
-- Applying it would be a no-op; ignoring it silently would hide an ingestion gap.
--
-- Out of scope, not malformed: these reverts are well formed, and they start
-- applying by themselves if the missing claim shows up in a later batch. That's
-- why the rule is here and not in `stg_reverts` — see `int_claims_scoped`.

with reverts as (

    select * from {{ ref('stg_reverts') }}
    where dq_reject_reason is null

),

analysable_claims as (

    select claim_id
    from {{ ref('int_claims_scoped') }}
    where scope_exclusion_reason is null

)

select
    r.* exclude (dq_reject_reason),

    case
        when c.claim_id is null then 'orphan_claim_id'
    end as scope_exclusion_reason

from reverts as r
left join analysable_claims as c using (claim_id)
