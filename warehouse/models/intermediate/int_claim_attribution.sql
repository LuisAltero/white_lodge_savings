-- Link each claim to the partner and channel that originated it.
--
-- ## The finding that shapes this model
--
-- **The claim event has no `partner`.** It has npi, ndc, price, quantity,
-- pbm_fee and timestamp. Commercial attribution exists only through the lookup
-- that converted — and that's where every fee split and every partner analysis
-- Dale asked for comes from. Which is why the funnel isn't a side report: it is
-- the critical path of revenue.
--
-- Verified on the sample: no claim has two lookups pointing at it, so the
-- relationship is 1:1 and `partner` / `channel` can be denormalised straight
-- onto fct_claim with no risk of row multiplication. The `qualify` below is the
-- seatbelt — if two ever arrive, the fact doesn't inflate; the earliest lookup
-- wins (it's the one that originated the search) and the discrepancy stays
-- visible in `attributing_lookup_count`.
--
-- 823 analysable claims have no lookup at all (1,539 before quarantine). They
-- aren't errors: they're fills that arrived without passing through our
-- price-lookup funnel. They become `direct` — a value of its own, not a NULL —
-- so they show up in `group by partner` instead of silently vanishing from every
-- commercial analysis.

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
