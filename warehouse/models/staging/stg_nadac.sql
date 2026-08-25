-- Weekly acquisition-cost snapshots per NDC, published by CMS.
--
-- **One row per (ndc, effective_date).** CMS republishes the same in-force price
-- every week under a new `as_of_date` until the price changes — 998k raw rows
-- collapse to 263k. The `qualify` keeps the most recent confirmation of each
-- price; two rows on one key would make the ASOF JOIN downstream ambiguous.
--
-- **Unit cost stays DOUBLE, not cents** — the one exception to this project's
-- money-as-integer rule. NADAC publishes to five decimals (0.26341 USD/unit), and
-- rounding before multiplying by quantity destroys precision: 0.26341 x 30 =
-- $7.90, but 0.26 x 30 = $7.80, a 1.3% error on every claim. The conversion
-- happens in `int_claim_cost`, once the value is actually an amount of money.

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
