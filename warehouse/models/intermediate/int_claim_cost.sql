-- Enrich each claim with its NADAC acquisition cost.
--
-- ## The decision: as-of the fill date
--
-- NADAC is a series of weekly snapshots — the same NDC carries up to 9 different
-- prices across 2026 (8.1 on average). "The cost of this drug" is not a number.
-- We chose: **the last price in force on the date the claim was filled**.
--
-- Note which date. `effective_date` is when a price took effect; `as_of_date` is
-- when CMS last republished it, 21 to 28 days later. The question here is
-- economic ("what did this drug cost that day"), so it joins on the business
-- date. Joining on the publication date would price every claim three weeks
-- stale: $7.7M of acquisition cost, 3.8%, against a $12.9M margin. `as_of_date`
-- would be the right key only for an audit — "what did we know at the time".
--
-- Why: it's the cost the market was actually charging on the day of the
-- transaction, so March margin is computed with March cost. And it's *stable* —
-- reprocessing history six months from now returns exactly the same numbers,
-- which is not true if you use "the latest snapshot".
--
-- This isn't an academic choice: in this data the unit cost of NDC 45802013430
-- varies 2x within 2026 ($0.86 to $1.72). Using the latest snapshot for
-- everything would halve that drug's margin.
--
-- What it costs: a claim whose NDC has no snapshot on or before the fill date
-- gets **no cost at all** — `cost_basis = 'no_match'`, and every cost column
-- NULL. 571 claims in the sample, all of them NDCs absent from NADAC entirely.
-- NULL and not zero: a zero would read as "this drug is free" and quietly
-- inflate pharmacy margin, whereas NULL is skipped by `avg()` and `sum()`.
--
-- ## Why ASOF JOIN and not a window function
--
-- DuckDB has a first-class operator for exactly this. The classic alternative —
-- cross every claim against all snapshots for its NDC, rank by `effective_date
-- desc`, keep the first — materialises the intermediate product before
-- filtering. ASOF JOIN resolves it as an ordered search, without blowing up
-- cardinality, and it says what it's doing in its own name.

with claims as (

    select * from {{ ref('int_claims_scoped') }}
    where scope_exclusion_reason is null

),

nadac as (

    select * from {{ ref('stg_nadac') }}

),

as_of as (

    select
        c.claim_id,
        n.nadac_unit_cost_usd  as unit_cost_usd,
        n.generic_unit_cost_usd,
        n.effective_date       as cost_effective_date,
        n.ndc_description,
        n.drug_class,
        n.pricing_unit,
        n.is_otc
    from claims as c
    asof left join nadac as n
        on c.ndc = n.ndc
       and c.filled_date >= n.effective_date

)

select
    c.*,
    a.unit_cost_usd,
    a.generic_unit_cost_usd,
    a.cost_effective_date,
    a.ndc_description,
    a.drug_class,
    a.pricing_unit,
    a.is_otc,

    case when a.unit_cost_usd is not null
        then 'as_of_fill_date' else 'no_match'
    end as cost_basis,

    -- Only here does cost become money, after multiplying by quantity.
    -- Rounding the unit rate before this point would lose ~1% per claim.
    {{ to_cents('a.unit_cost_usd * c.quantity') }}         as est_acquisition_cost_cents,
    {{ to_cents('a.generic_unit_cost_usd * c.quantity') }} as est_generic_cost_cents,
    a.unit_cost_usd is not null as has_cost_match

from claims as c
left join as_of as a using (claim_id)
