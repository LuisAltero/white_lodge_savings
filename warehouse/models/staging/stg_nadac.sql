-- Weekly acquisition-cost snapshots per NDC, published by CMS.
--
-- **Unit cost stays DOUBLE, not cents.** It is the one exception to this
-- project's money-as-integer rule, and it's deliberate: NADAC publishes rates to
-- five decimal places (0.26341 USD/unit). Rounding to the cent *before*
-- multiplying by quantity destroys precision — 0.26341 × 30 = $7.90, but
-- 0.26 × 30 = $7.80, a 1.3% error on every claim. The conversion to cents
-- happens after the multiplication, in `int_claim_cost`, when the value actually
-- becomes an amount of money.
--
-- One row per (ndc, effective_date): CMS republishes the same in-force price
-- across several `as_of_date` values. We keep the most recent snapshot that
-- confirmed that price; multiple rows per key would break the ASOF JOIN
-- downstream.

with source as (

    select * from {{ source('raw', 'nadac') }}

),

parsed as (

    select
        nullif(trim(ndc), '') as ndc,
        trim(ndc_description) as ndc_description,
        try_cast(nadac_per_unit as double)         as nadac_unit_cost_usd,
        try_cast(generic_nadac_per_unit as double) as generic_unit_cost_usd,

        -- CMS publishes dates as MM/DD/YYYY; try_strptime returns NULL instead
        -- of raising if the format ever changes in a future republication.
        cast(try_strptime(effective_date, '%m/%d/%Y') as date) as effective_date,
        cast(try_strptime(as_of_date, '%m/%d/%Y') as date)     as as_of_date,

        upper(trim(pricing_unit)) as pricing_unit,
        case upper(trim(classification_for_rate_setting))
            when 'B' then 'brand'
            when 'G' then 'generic'
            else 'unknown'
        end as drug_class,
        upper(trim(otc)) = 'Y' as is_otc
    from source

)

select *
from parsed
where ndc is not null
  and effective_date is not null
  and nadac_unit_cost_usd is not null
  and nadac_unit_cost_usd > 0
qualify row_number() over (
    partition by ndc, effective_date
    order by as_of_date desc
) = 1
