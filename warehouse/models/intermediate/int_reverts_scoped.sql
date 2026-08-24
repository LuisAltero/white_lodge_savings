-- Reversals that survived staging, resolved against the analysable claim
-- universe.
--
-- `orphan_claim_id` (53 rows): the reversal arrived but the claim it invalidates
-- isn't in our universe — either it never landed, or it was itself rejected
-- (malformed) or excluded (unknown NPI). Applying that reversal would be a
-- no-op; ignoring it silently would hide an ingestion gap.
--
-- Out of scope, not malformed: these reverts are well formed, and if the missing
-- claim shows up in a later batch they start applying by themselves. That's why
-- the rule lives here rather than in `stg_reverts`, and why the column is named
-- `scope_exclusion_reason` — see `int_claims_scoped` for the full argument.

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
