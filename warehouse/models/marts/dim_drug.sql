-- One row per NDC seen in our events, with NADAC attributes.
--
-- The grain is *the NDC that appears in our data*, not the whole NADAC catalogue
-- (998k rows, 26k drugs we never dispense). A dimension describes our business.
--
-- Attributes come from the drug's most recent NADAC snapshot — commercial
-- description and brand/generic classification don't change week to week. What
-- changes is price, and price is not a dimension attribute; it's a fact measure
-- (`int_claim_cost`).
--
-- `is_in_nadac = false` marks the NDCs that never match (three in the sample:
-- 77777000303, 88888000202, 99999000101). They stay in the dimension because
-- they generated real claims with real revenue — they just have no cost, and
-- therefore no computable margin. Dropping them would hide genuine volume.

with observed_ndcs as (

    select ndc from {{ ref('int_claims_scoped') }} where scope_exclusion_reason is null
    union
    select ndc from {{ ref('int_lookups_resolved') }}

),

latest_attributes as (

    select
        ndc,
        ndc_description,
        drug_class,
        pricing_unit,
        is_otc,
        nadac_unit_cost_usd   as latest_unit_cost_usd,
        generic_unit_cost_usd as latest_generic_unit_cost_usd,
        effective_date        as latest_cost_effective_date
    from {{ ref('stg_nadac') }}
    qualify row_number() over (partition by ndc order by effective_date desc) = 1

)

select
    o.ndc,
    coalesce(n.ndc_description, '(not in NADAC)') as ndc_description,
    coalesce(n.drug_class, 'unknown') as drug_class,
    n.pricing_unit,
    n.is_otc,
    n.latest_unit_cost_usd,
    n.latest_generic_unit_cost_usd,
    n.latest_cost_effective_date,
    n.ndc is not null as is_in_nadac
from observed_ndcs as o
left join latest_attributes as n using (ndc)
