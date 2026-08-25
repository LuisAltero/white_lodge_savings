-- Link each claim to the partner and channel that originated it.
--
-- **The claim event has no `partner`.** It has npi, ndc, price, quantity, pbm_fee
-- and timestamp. Commercial attribution exists only through the lookup that
-- converted — which is why the funnel isn't a side report but the critical path
-- of revenue, and where every fee split and partner analysis comes from.
--
-- Verified: no claim has two lookups pointing at it, so the relationship is 1:1
-- and `partner` / `channel` denormalise onto `fct_claim` with no risk of row
-- multiplication. The `qualify` is the seatbelt — if two ever arrive the earliest
-- wins (it originated the search) and `attributing_lookup_count` keeps the
-- discrepancy visible.
--
-- 823 analysable claims have no lookup at all (1,544 before quarantine). They
-- aren't errors — they're fills that never passed through our price-lookup
-- funnel. They become `direct`, a value of its own rather than a NULL, so they
-- appear in `group by partner` instead of vanishing from every commercial cut.

with converted_lookups as (

    select
        claim_id,
        partner,
        channel,
        looked_up_at,
        lookup_id
    from {{ ref('int_lookups_resolved') }}
    where claim_id is not null

),

deduplicated as (

    select
        *,
        count(*) over (partition by claim_id) as attributing_lookup_count
    from converted_lookups
    qualify row_number() over (partition by claim_id order by looked_up_at) = 1

)

select
    claim_id,
    coalesce(partner, 'direct') as partner,
    coalesce(channel, 'direct') as channel,
    lookup_id as attributing_lookup_id,
    looked_up_at,
    attributing_lookup_count
from deduplicated
