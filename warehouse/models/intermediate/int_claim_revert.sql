-- Resolve each claim's reversal state.
--
-- **Why a reversal is a column and not its own fact.** A revert isn't a business
-- event with value of its own — it's a *correction*. The brief is direct: a
-- reversed claim is treated as if the fill never happened, for revenue, volume,
-- fees and payouts.
--
-- As a separate fact, every money question becomes an anti-join ("claims that
-- don't appear in fct_revert") — exactly the join people forget to write at 3pm
-- in a live session, producing inflated revenue that *looks* right. As a column,
-- the same question is a `where`, and the safe default is obvious. Timing isn't
-- lost: `reverted_at` and `hours_to_revert` sit on the same row.
--
-- If a claim were ever reverted twice we keep the earliest — the first reversal
-- is the one that invalidated the fill. The tie-break never fires here: the 26
-- duplicate revert ids are quarantined in staging, and no claim reaches this
-- model with two reverts. `revert_event_count` is what proves that rather than
-- assuming it.

with reverts as (

    select * from {{ ref('int_reverts_scoped') }}
    where scope_exclusion_reason is null

)

select
    claim_id,
    reverted_at,
    revert_id,
    count(*) over (partition by claim_id) as revert_event_count
from reverts
qualify row_number() over (partition by claim_id order by reverted_at) = 1
