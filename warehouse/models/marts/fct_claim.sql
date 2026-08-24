-- **The central table of the warehouse. Grain: one valid claim.**
--
-- ## Why a wide fact and not a strict star
--
-- The attributes almost every question uses — `chain`, `partner`, `channel`,
-- `drug_class` — are denormalised here alongside the foreign keys. The
-- dimensions still exist (`dim_pharmacy`, `dim_partner`, `dim_drug`) and hold
-- the long-tail attributes.
--
-- The reason is the usage context: questions arrive live, on a shared screen.
-- "Revenue by chain last month" has to be one `select ... group by` against one
-- table. In a strict star it's three joins written under time pressure, and the
-- expensive mistake isn't typing slowly — it's getting the join wrong and
-- presenting a plausible, false number.
--
-- What the denormalisation costs: `chain` lives in two places and could drift if
-- reference data changed between runs. With a full reload each run, both sides
-- are rebuilt from the same source in the same run, so they don't drift.
--
-- ## The safe default
--
-- A reversed claim is as if it never happened. Rather than trusting everyone to
-- remember `where not is_reverted`, the `net_*_cents` columns are already zeroed
-- on reversed rows. Summing `net_wls_revenue_cents` with no filter at all gives
-- the right number; `gross_*` stays available for measuring what was reversed.

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

pharmacies as (

    select npi, chain from {{ ref('stg_pharmacies') }}

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
        e.wls_net_fee_cents,
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
    left  join pharmacies  as p on c.npi = p.npi

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
    case when is_reverted then 0 else wls_net_fee_cents end as net_wls_revenue_cents,
    case when is_reverted then 0 else 1 end                 as net_claim_count

from assembled
