-- **Grain: one price-lookup event.** The top of the funnel.
--
-- A separate fact from fct_claim because the grain is different and most of
-- these rows never become a claim — 177k lookups for 42k claims. Squeezing both
-- into one table would mean either losing the 135k non-converted rows, or a fact
-- with half its columns NULL and no declarable grain.
--
-- The bridge between the two is `claim_id`, and it's 1:1 where it exists. Funnel
-- = count from this table, revenue = sum from the other, and `converted` is the
-- only link.

with lookups as (

    select * from {{ ref('int_lookups_resolved') }}

),

claims as (

    select claim_id, chain, pharmacy_npi, is_reverted, net_wls_revenue_cents
    from {{ ref('fct_claim') }}

)

select
    l.lookup_id,
    l.claim_id,
    l.ndc,
    l.partner,
    l.channel,
    l.looked_up_at,
    l.lookup_date,

    l.converted,
    l.has_unresolvable_claim_id,
    l.partner_was_missing,

    -- Pull the claim's outcome down to the lookup: "conversions that earned how
    -- much" and "conversions that got reversed" become single-table queries.
    c.chain,
    c.pharmacy_npi,
    coalesce(c.is_reverted, false)       as converted_and_reverted,
    coalesce(c.net_wls_revenue_cents, 0) as net_wls_revenue_cents,

    l._source_file
from lookups as l
left join claims as c using (claim_id)
