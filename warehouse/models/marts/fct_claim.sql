-- **The central table of the warehouse. Grain: one valid claim.**
--
-- ## A wide fact, not a strict star
--
-- `chain`, `partner`, `channel` and `drug_class` are denormalised here alongside
-- the foreign keys; the dimensions still exist and hold the long tail.
--
-- The reason is the usage context: questions arrive live, on a shared screen.
-- "Revenue by chain last month" has to be one `select ... group by` against one
-- table. In a strict star it's three joins under time pressure, and the expensive
-- mistake isn't typing slowly — it's getting a join wrong and presenting a
-- plausible, false number. The cost is that `chain` lives in two places; with a
-- full reload each run both sides rebuild from the same source, so they can't
-- drift.
--
-- ## The safe default
--
-- A reversed claim is as if it never happened, so the `net_*_cents` columns are
-- already zeroed on reversed rows — summing with no filter gives the right
-- number, rather than trusting everyone to remember `where not is_reverted`. The
-- unprefixed columns (`price_cents`, `pbm_fee_cents`, `wls_fee_cents`) are the
-- gross values, for measuring what was reversed.
--
-- The prefix carries the whole meaning: `net_` means *net of reversals*, and
-- nothing else in this table uses the word.
--
-- ## Two dates: this is an accumulating snapshot
--
-- One row per claim, tracking a lifecycle with two milestones — the fill
-- (`filled_at`) and, if it comes, the reversal (`reverted_at`). The row is
-- rewritten when the later one lands, which is exactly why a revert is a column
-- here rather than its own fact.
--
-- The consequence isn't free: **`net_*` is measured at `filled_date`, so history
-- restates.** 712 of the 2,739 reversals (26%) land in a different month than the
-- fill they cancel, so a claim filled in March and reverted in July removes
-- revenue *from March* on the next run. March is "March as we understand it
-- today", not "March as we reported it in April".
--
-- That's right for the question in play (true economics of a cohort of fills),
-- and it's why `mart_funnel_daily` keeps the two dates under different names.
-- What it costs is period comparability: "revenue as reported at month close"
-- would need a dated snapshot of this table, which does not exist here.

with claims as (

    select * from {{ ref('int_claim_cost') }}

),

economics as (

    select * from {{ ref('int_claim_economics') }}

),

attribution as (

    select * from {{ ref('int_claim_attribution') }}

),

reverts as (

    select * from {{ ref('int_claim_revert') }}

),

-- `chain` comes from the dimension, not from stg_pharmacies. Both hold the same
-- value, but a fact reaching back past its own dimension into staging is a
-- second path to the same attribute — and the day someone adds a rule to
-- dim_pharmacy, the fact quietly stops agreeing with it.
pharmacies as (

    select pharmacy_npi, chain from {{ ref('dim_pharmacy') }}

),

assembled as (

    select
        c.claim_id,
        c.npi as pharmacy_npi,
        p.chain,
        c.ndc,
        e.partner,
        coalesce(a.channel, 'direct') as channel,
        c.drug_class,

        c.filled_at,
        c.filled_date,

        c.quantity,
        c.price_cents,
        c.pbm_fee_cents,
        e.partner_fee_cents,
        e.wls_fee_cents,
        e.fee_model,
        e.partner_fee_was_capped,
        e.capped_shortfall_cents,

        c.unit_cost_usd,
        c.est_acquisition_cost_cents,
        c.est_generic_cost_cents,
        c.cost_basis,
        c.cost_effective_date,
        c.has_cost_match,

        r.reverted_at is not null as is_reverted,
        r.reverted_at,
        r.revert_id,
        date_diff('hour', c.filled_at, r.reverted_at) as hours_to_revert,

        a.attributing_lookup_id,
        a.looked_up_at,
        date_diff('minute', a.looked_up_at, c.filled_at) as minutes_lookup_to_fill,

        c._source_file
    from claims as c
    inner join economics   as e using (claim_id)
    left  join attribution as a using (claim_id)
    left  join reverts     as r using (claim_id)
    left  join pharmacies  as p on c.npi = p.pharmacy_npi

)

select
    *,

    -- Pharmacy margin: what it charged, minus what it paid for the drug, minus
    -- our fee. NULL when the NDC doesn't match NADAC — and NULL here is
    -- deliberate: `avg()` skips it, `sum()` skips it, and nobody sums a zero
    -- thinking it's zero margin when it's actually unknown margin.
    case when has_cost_match
        then price_cents - est_acquisition_cost_cents - pbm_fee_cents
    end as pharmacy_margin_cents,

    -- Generic-substitution opportunity: how much acquisition cost disappears if
    -- the same fill used the equivalent generic NADAC points at. Only meaningful
    -- for a brand drug that has a published generic.
    case when drug_class = 'brand' and est_generic_cost_cents is not null
        then est_acquisition_cost_cents - est_generic_cost_cents
    end as generic_substitution_savings_cents,

    -- The "net" columns already respect reversals. This is the safe default.
    case when is_reverted then 0 else price_cents end       as net_price_cents,
    case when is_reverted then 0 else pbm_fee_cents end     as net_pbm_fee_cents,
    case when is_reverted then 0 else partner_fee_cents end as net_partner_fee_cents,
    case when is_reverted then 0 else wls_fee_cents end as net_wls_revenue_cents,
    case when is_reverted then 0 else 1 end                 as net_claim_count

from assembled
