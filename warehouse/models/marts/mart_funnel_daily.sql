-- **Grain: day x partner x channel.** The lookup -> claim -> reversal funnel.
--
-- Built off the calendar (`dim_date`), not off the events: a day when Flink Rx
-- converted nothing has to show up as a zero, or the hole in the series reads as
-- a gentle decline and nobody notices. Finer questions (per drug, per pharmacy)
-- go straight to `fct_claim` — pre-aggregating every combination only creates
-- tables nobody knows whether to trust.
--
-- ## Two different reversal numbers, on purpose
--
-- A reversal has two dates — the fill and the reversal — and 26% of them fall in
-- different months. One column cannot mean both, so there are two, and neither is
-- called `reverted_claims`:
--
-- * `claims_filled_then_reverted` — of the claims *filled* this day, how many
--   were ever reverted. A **cohort** measure, keyed on `filled_date`; it's what
--   `cohort_reversal_rate` divides, and the honest way to compare partners
--   ("does Druid Rx send fills that stick?").
-- * `reverts_on_day` — how many reversals actually *happened* this day, keyed on
--   `reverted_at`, with `revenue_reversed_cents` beside it. An **activity**
--   measure: "what did we hand back last week?"
--
-- Over the whole period both sum to 2,739. Over any shorter window they don't,
-- and that difference is the point.

with lookups as (

    select
        lookup_date as date_day,
        partner,
        channel,
        count(*)                                          as lookups,
        count(*) filter (where converted)                 as conversions,
        count(*) filter (where has_unresolvable_claim_id) as unresolvable_conversions
    from {{ ref('fct_lookup') }}
    group by 1, 2, 3

),

-- Keyed on the fill date: the cohort side.
claims as (

    select
        filled_date as date_day,
        partner,
        channel,
        count(*)                            as claims,
        count(*) filter (where is_reverted) as claims_filled_then_reverted,
        sum(net_price_cents)                as net_gmv_cents,
        sum(net_wls_revenue_cents)          as net_wls_revenue_cents,
        sum(net_partner_fee_cents)          as net_partner_payout_cents
    from {{ ref('fct_claim') }}
    group by 1, 2, 3

),

-- Keyed on the reversal date: the activity side. `wls_fee_cents` and not
-- `net_wls_revenue_cents` — the net_* columns are already zeroed on a reverted
-- row, so the amount handed back is the gross one.
reverts as (

    select
        cast(reverted_at as date) as date_day,
        partner,
        channel,
        count(*)               as reverts_on_day,
        sum(wls_fee_cents) as revenue_reversed_cents,
        sum(price_cents)       as gmv_reversed_cents
    from {{ ref('fct_claim') }}
    where is_reverted
    group by 1, 2, 3

),

spine as (

    select date_day, partner, channel from lookups
    union
    select date_day, partner, channel from claims
    union
    select date_day, partner, channel from reverts

)

select
    d.date_day,
    d.month_start,
    d.week_start,
    d.day_name,
    d.is_weekend,
    s.partner,
    s.channel,

    coalesce(l.lookups, 0)      as lookups,
    coalesce(l.conversions, 0)  as conversions,
    coalesce(c.claims, 0)       as claims,
    coalesce(l.unresolvable_conversions, 0) as unresolvable_conversions,

    -- Cohort side: keyed on the day of the fill.
    coalesce(c.claims_filled_then_reverted, 0) as claims_filled_then_reverted,

    -- Activity side: keyed on the day of the reversal.
    coalesce(r.reverts_on_day, 0)          as reverts_on_day,
    coalesce(r.revenue_reversed_cents, 0)  as revenue_reversed_cents,
    coalesce(r.gmv_reversed_cents, 0)      as gmv_reversed_cents,

    coalesce(c.net_gmv_cents, 0)            as net_gmv_cents,
    coalesce(c.net_wls_revenue_cents, 0)    as net_wls_revenue_cents,
    coalesce(c.net_partner_payout_cents, 0) as net_partner_payout_cents,

    {{ safe_divide('l.conversions', 'l.lookups') }} as conversion_rate,
    {{ safe_divide('c.claims_filled_then_reverted', 'c.claims') }}
        as cohort_reversal_rate
from spine as s
inner join {{ ref('dim_date') }} as d using (date_day)
left join lookups as l using (date_day, partner, channel)
left join claims  as c using (date_day, partner, channel)
left join reverts as r using (date_day, partner, channel)
