-- Enrich each claim with its NADAC acquisition cost.
--
-- ## The decision: as-of the fill date
--
-- NADAC is a series of weekly snapshots — the same NDC appears 33 times in 2026
-- alone. "The cost of this drug" is not a number. We chose: **the last price in
-- force on the date the claim was filled**.
--
-- Why: it's the cost the market was actually charging on the day of the
-- transaction, so March margin is computed with March cost. And it's *stable* —
-- reprocessing history six months from now returns exactly the same numbers,
-- which is not true if you use "the latest snapshot".
--
-- What it costs: the join is more expensive than a single-value lookup, and
-- claims predating an NDC's first snapshot don't match (hence the fallback).
--
-- This isn't an academic choice: in this data the unit cost of NDC 45802013430
-- varies 2× within 2026 ($0.86 to $1.72). Using the latest snapshot for
-- everything would halve that drug's margin.
--
-- ## Why ASOF JOIN and not a window function
--
-- DuckDB has a first-class operator for exactly this. The classic alternative —
-- cross every claim against all snapshots for its NDC, rank by `effective_date
-- desc`, keep the first — materialises the intermediate product before
-- filtering. ASOF JOIN resolves it as an ordered search, without blowing up
-- cardinality, and it says what it's doing in its own name.

with claims as (

    select * from {{ ref('stg_claims') }}
    where dq_reject_reason is null

),

nadac as (

    select * from {{ ref('stg_nadac') }}

),

-- Fallback: the oldest snapshot that exists for each NDC. Used when a claim
-- predates any published price for that drug — better to anchor on the first
-- known cost than to throw the margin away. `cost_basis` labels those rows, so
-- they can be excluded from a cost-sensitive analysis rather than discovered
-- afterwards.
earliest_known as (

    select ndc, nadac_unit_cost_usd, effective_date, ndc_description,
           drug_class, pricing_unit, is_otc, generic_unit_cost_usd
    from nadac
    qualify row_number() over (partition by ndc order by effective_date) = 1

),

as_of as (

    select
        c.claim_id,
        n.nadac_unit_cost_usd,
        n.generic_unit_cost_usd,
        n.effective_date,
        n.ndc_description,
        n.drug_class,
        n.pricing_unit,
        n.is_otc
    from claims as c
    asof left join nadac as n
        on c.ndc = n.ndc
       and c.filled_date >= n.effective_date

),

resolved as (

    select
        c.*,
        coalesce(a.nadac_unit_cost_usd, e.nadac_unit_cost_usd)     as unit_cost_usd,
        coalesce(a.generic_unit_cost_usd, e.generic_unit_cost_usd) as generic_unit_cost_usd,
        coalesce(a.effective_date, e.effective_date)               as cost_effective_date,
        coalesce(a.ndc_description, e.ndc_description)             as ndc_description,
        coalesce(a.drug_class, e.drug_class)                       as drug_class,
        coalesce(a.pricing_unit, e.pricing_unit)                   as pricing_unit,
        coalesce(a.is_otc, e.is_otc)                               as is_otc,
        case
            when a.nadac_unit_cost_usd is not null then 'as_of_fill_date'
            when e.nadac_unit_cost_usd is not null then 'earliest_available'
            else 'no_match'
        end as cost_basis
    from claims as c
    left join as_of as a using (claim_id)
    left join earliest_known as e on c.ndc = e.ndc

)

select
    *,
    -- Only here does cost become money, after multiplying by quantity.
    -- Rounding the unit rate before this point would lose ~1% per claim.
    {{ to_cents('unit_cost_usd * quantity') }}        as est_acquisition_cost_cents,
    {{ to_cents('generic_unit_cost_usd * quantity') }} as est_generic_cost_cents,
    cost_basis <> 'no_match' as has_cost_match
from resolved
