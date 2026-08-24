-- Resolve each claim's reversal state.
--
-- ## Why a reversal is a column and not its own fact table
--
-- A revert isn't a business event with value of its own — it's a *correction* to
-- the claim. The brief is direct: a reversed claim is treated as if the fill
-- never happened, for revenue, volume, fees and payouts.
--
-- If reverts were a separate fact, every money question would become an
-- anti-join ("claims that don't appear in fct_revert") — and that's exactly the
-- join people forget to write at 3pm in a live session, producing inflated
-- revenue that *looks* right. As a column (`is_reverted`), the same question is
-- a `where`, and the safe default is obvious.
--
-- Reversal timing isn't lost: `reverted_at` and `hours_to_revert` sit on the
-- same row, so "how long do reversals take" stays a single-table query.
--
-- One claim is reverted twice in the sample. The first reversal is the one that
-- invalidated the fill; the second is producer noise. We keep the earliest.

with reverts as (

    select * from {{ ref('stg_reverts') }}
    where dq_reject_reason is null

)

select
    claim_id,
    reverted_at,
    revert_id,
    count(*) over (partition by claim_id) as revert_event_count
from reverts
qualify row_number() over (partition by claim_id order by reverted_at) = 1
