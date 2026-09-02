-- **Grain: one NDC.** Where the margin is — Gordon's question.
--
-- Puts the three per-drug levers on one row: what White Lodge retains, how much
-- is lost to reversals, and how much acquisition cost would come out if the fill
-- used the equivalent generic NADAC publishes.
--
-- `revenue_at_risk_from_reversals_cents` is the one that tends to surprise: it's
-- revenue already earned and handed back, and unlike margin that never existed,
-- it is recoverable.

with claims as (

    select * from {{ ref('fct_claim') }}

),

lookups as (

    select ndc, count(*) as lookups
    from {{ ref('fct_lookup') }}
    group by 1

),

by_drug as (

    select
        ndc,
        count(*)                            as claims,
        sum(net_claim_count)                as net_claims,
        count(*) filter (where is_reverted) as reverted_claims,
        sum(quantity) filter (where not is_reverted) as net_units,

        sum(net_price_cents)                as net_gmv_cents,
        sum(net_wls_revenue_cents)          as net_wls_revenue_cents,
        sum(net_partner_fee_cents)          as net_partner_payout_cents,

        -- Revenue lost to reversals: what we would have retained on reverted claims.
        sum(wls_fee_cents) filter (where is_reverted)
            as revenue_at_risk_from_reversals_cents,

        sum(est_acquisition_cost_cents) filter (where not is_reverted)
            as net_acquisition_cost_cents,
        sum(pharmacy_margin_cents) filter (where not is_reverted)
            as net_pharmacy_margin_cents,
        sum(generic_substitution_savings_cents) filter (where not is_reverted)
            as generic_substitution_savings_cents,

        avg(unit_cost_usd)                  as avg_unit_cost_usd,
        count(*) filter (where not has_cost_match) as claims_without_cost,
        count(distinct pharmacy_npi)        as distinct_pharmacies,
        count(distinct partner)             as distinct_partners
    from claims
    group by 1

)

select
    d.ndc,
    d.ndc_description,
    d.drug_class,
    d.is_otc,
    d.is_in_nadac,

    b.claims,
    b.net_claims,
    b.reverted_claims,
    b.net_units,

    b.net_gmv_cents,
    b.net_wls_revenue_cents,
    b.net_partner_payout_cents,
    b.net_acquisition_cost_cents,
    b.net_pharmacy_margin_cents,

    coalesce(b.revenue_at_risk_from_reversals_cents, 0)
        as revenue_at_risk_from_reversals_cents,
    coalesce(b.generic_substitution_savings_cents, 0)
        as generic_substitution_savings_cents,

    {{ safe_divide('b.reverted_claims', 'b.claims') }}      as reversal_rate,
    {{ safe_divide('b.claims', 'l.lookups') }}              as conversion_rate,
    {{ safe_divide('b.net_wls_revenue_cents', 'b.net_gmv_cents') }} as wls_take_rate,
    {{ safe_divide('b.net_pharmacy_margin_cents', 'b.net_gmv_cents') }} as pharmacy_margin_rate,

    coalesce(l.lookups, 0) as lookups,
    b.avg_unit_cost_usd,
    b.claims_without_cost,
    b.distinct_pharmacies,
    b.distinct_partners
from {{ ref('dim_drug') }} as d
left join by_drug as b using (ndc)
left join lookups as l using (ndc)
