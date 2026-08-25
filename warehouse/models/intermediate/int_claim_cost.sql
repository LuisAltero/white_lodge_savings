-- Enrich each claim with its NADAC acquisition cost.
--
-- ## The decision: as-of the fill date
--
-- NADAC is a series of weekly snapshots — the same NDC carries up to 9 different
-- prices across 2026. "The cost of this drug" is not a number, so we take **the
-- last price in force on the date the claim was filled**: the cost the market was
-- charging that day, and *stable*, since reprocessing this history later returns
-- the same numbers. Not academic — NDC 45802013430 ranges $0.86 to $1.72 within
-- 2026, so one number for the year halves or doubles that drug's margin.
--
-- **Note which date.** `effective_date` is when a price took effect; `as_of_date`
-- is when CMS last republished it, 21 to 28 days later. Joining on the
-- publication date would price every claim three weeks stale — $7.7M, 3.8%,
-- against a $12.9M margin. It's the right key only for an audit ("what did we
-- know at the time"), and the question here is economic.
--
-- **What it costs.** A claim whose NDC has no snapshot on or before the fill date
-- gets no cost at all: `cost_basis = 'no_match'`, every cost column NULL. 571
-- claims, all on NDCs absent from NADAC entirely. NULL and not zero — zero reads
-- as "this drug is free" and inflates margin, while NULL is skipped by `avg()`
-- and `sum()`.
--
-- **Why ASOF and not a window function.** The classic alternative crosses every
-- claim against all snapshots for its NDC and ranks them, materialising the whole
-- product before filtering. ASOF resolves it as an ordered search without
-- inflating cardinality, and says what it's doing in its own name.

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
