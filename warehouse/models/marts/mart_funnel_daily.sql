-- **Grain: day × partner × channel.** The lookup -> claim -> reversal funnel.
--
-- Built off the calendar (`dim_date`), not off the events: a day when Flink Rx
-- converted nothing has to show up as zero, otherwise the hole in the series
-- reads as a gentle decline on the chart and nobody notices.
--
-- This is the right grain for the time series and the channel cut. Finer
-- questions (per drug, per pharmacy) go straight to fct_claim — we don't
-- pre-aggregate every possible combination, that only creates tables nobody
-- knows whether to trust.

with lookups as (

    select
        lookup_date as date_day,
        partner,
        channel,
        count(*)                             as lookups,
        count(*) filter (where converted)     as conversions,
        count(*) filter (where has_unresolvable_claim_id) as unresolvable_conversions
    from {{ ref('fct_lookup') }}
    group by 1, 2, 3

),

claims as (

    select
        filled_date as date_day,
        partner,
        channel,
        count(*)                             as claims,
        count(*) filter (where is_reverted)   as reverted_claims,
        sum(net_price_cents)                 as net_gmv_cents,
        sum(net_wls_revenue_cents)           as net_wls_revenue_cents,
        sum(net_partner_fee_cents)           as net_partner_payout_cents
    from {{ ref('fct_claim') }}
    group by 1, 2, 3

),

spine as (

    select date_day, partner, channel from lookups
    union
    select date_day, partner, channel from claims

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
    coalesce(c.reverted_claims, 0) as reverted_claims,
    coalesce(l.unresolvable_conversions, 0) as unresolvable_conversions,

    coalesce(c.net_gmv_cents, 0)            as net_gmv_cents,
    coalesce(c.net_wls_revenue_cents, 0)    as net_wls_revenue_cents,
    coalesce(c.net_partner_payout_cents, 0) as net_partner_payout_cents,

    {{ safe_divide('l.conversions', 'l.lookups') }}   as conversion_rate,
    {{ safe_divide('c.reverted_claims', 'c.claims') }} as reversal_rate
from spine as s
inner join {{ ref('dim_date') }} as d using (date_day)
left join lookups as l using (date_day, partner, channel)
left join claims  as c using (date_day, partner, channel)
