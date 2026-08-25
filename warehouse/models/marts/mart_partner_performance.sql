-- **Grain: one partner.** The commercial summary behind Dale's question.
--
-- A small aggregate like this doesn't exist for performance — the fact is 41k
-- rows and DuckDB scans that in milliseconds. It exists to *pin the definition*:
-- a partner's value is `net_wls_revenue_cents`, what White Lodge keeps after the
-- payout and after reversals. Without that written down, two people answer "who
-- is our best partner" with gross and with net revenue and land on different
-- partners. The difference is real: a partner driving heavy volume while keeping
-- 80% of the fee is worth less than a smaller flat-cut one.

with claims as (

    select * from {{ ref('fct_claim') }}

),

lookups as (

    select
        partner,
        count(*)                        as lookups,
        count(distinct ndc)             as distinct_drugs_looked_up,
        count(*) filter (where channel = 'integration') as lookups_integration,
        count(*) filter (where channel = 'website')     as lookups_website
    from {{ ref('fct_lookup') }}
    group by 1

),

claim_side as (

    select
        partner,
        count(*)                                  as claims,
        count(*) filter (where is_reverted)        as reverted_claims,
        sum(net_claim_count)                      as net_claims,

        sum(net_price_cents)                      as net_gmv_cents,
        sum(net_pbm_fee_cents)                    as net_pbm_fee_cents,
        sum(net_partner_fee_cents)                as net_partner_payout_cents,
        sum(net_wls_revenue_cents)                as net_wls_revenue_cents,

        sum(price_cents)                          as gross_gmv_cents,
        sum(pbm_fee_cents)                        as gross_pbm_fee_cents,

        sum(capped_shortfall_cents)               as capped_shortfall_cents,
        count(*) filter (where partner_fee_was_capped) as capped_claims,

        avg(pharmacy_margin_cents)                as avg_pharmacy_margin_cents,
        count(distinct pharmacy_npi)              as distinct_pharmacies,
        count(distinct ndc)                       as distinct_drugs,
        min(filled_date)                          as first_claim_date,
        max(filled_date)                          as last_claim_date
    from claims
    group by 1

)

select
    d.partner_name as partner,
    d.fee_model,
    d.flat_fee_cents,
    d.fee_rate,
    d.is_synthetic,

    coalesce(l.lookups, 0)  as lookups,
    coalesce(c.claims, 0)   as claims,
    coalesce(c.net_claims, 0) as net_claims,
    coalesce(c.reverted_claims, 0) as reverted_claims,

    coalesce(c.net_wls_revenue_cents, 0)     as net_wls_revenue_cents,
    coalesce(c.net_partner_payout_cents, 0)  as net_partner_payout_cents,
    coalesce(c.net_pbm_fee_cents, 0)         as net_pbm_fee_cents,
    coalesce(c.net_gmv_cents, 0)             as net_gmv_cents,
    coalesce(c.gross_pbm_fee_cents, 0)       as gross_pbm_fee_cents,

    -- How much of every dollar of fee collected stays with us. This is the
    -- metric that separates "big partner" from "profitable partner".
    {{ safe_divide('c.net_wls_revenue_cents', 'c.net_pbm_fee_cents') }} as wls_fee_retention,
    {{ safe_divide('c.claims', 'l.lookups') }}                          as conversion_rate,
    {{ safe_divide('c.reverted_claims', 'c.claims') }}                  as reversal_rate,
    {{ safe_divide('c.net_wls_revenue_cents', 'l.lookups') }}           as revenue_cents_per_lookup,
    {{ safe_divide('c.net_wls_revenue_cents', 'c.net_claims') }}        as revenue_cents_per_net_claim,

    coalesce(c.capped_claims, 0) as capped_claims,
    coalesce(c.capped_shortfall_cents, 0) as capped_shortfall_cents,
    c.avg_pharmacy_margin_cents,
    c.distinct_pharmacies,
    c.distinct_drugs,
    coalesce(l.lookups_integration, 0) as lookups_integration,
    coalesce(l.lookups_website, 0)     as lookups_website,
    c.first_claim_date,
    c.last_claim_date
from {{ ref('dim_partner') }} as d
left join claim_side as c on d.partner_name = c.partner
left join lookups    as l on d.partner_name = l.partner
