-- Splitting the pbm_fee between White Lodge and the partner.
--
-- This is the most delicate logic in the project — our revenue literally comes
-- out of it — so it lives in its own small, testable model rather than buried in
-- a giant expression inside the fact table. Every branch is exercised by unit
-- tests in `_unit_tests.yml`.
--
-- ## The rules
--
-- * `fee_cents`: flat cut, in cents.
-- * `fee_percentage`: proportional share of the pbm_fee (normalised to 0-1 in
--   stg_partners).
-- * Claim with no attributed partner (`direct`): White Lodge keeps the whole
--   fee. There is nobody to pay out to.
--
-- ## The cap, and what measuring it revealed
--
-- 471 *raw* claims have a `pbm_fee` below $1.00, and Kafka Rx charges a flat
-- $1.00. Reading the file, that looks like a landmine: payout larger than the
-- fee collected, negative revenue. So I wrote the cap — `least(fee, pbm_fee)`,
-- the partner never takes more than we collected — and instrumented it with
-- `partner_fee_was_capped` to measure the damage.
--
-- **The flag fires zero times.** Of those 471, 460 are from pharmacies outside
-- the reference data and land in quarantine before reaching here; the other 11
-- are duplicates, non-positive amounts and an unreadable timestamp. The lowest
-- `pbm_fee` in the analysable population is $1.08. The conflict was an artefact
-- of dirty data, not a commercial rule.
--
-- The cap stays, for two reasons: it's a cheap invariant against the case
-- showing up in a future batch, and the flag column is what turns "I don't think
-- this happens" into "I measured it, it's zero rows". If they ever appear, the
-- amount in dispute is exactly `sum(capped_shortfall_cents)`.
--
-- Worth saying that the cap is a *modelling* decision, not a known fact: the
-- real contract may well have White Lodge eat the difference. Swapping
-- `least(...)` for the raw value is one line, and the flag still answers "how
-- much does this change".

with claims as (

    select claim_id, pbm_fee_cents
    from {{ ref('stg_claims') }}
    where dq_reject_reason is null

),

attributed as (

    select
        c.claim_id,
        c.pbm_fee_cents,
        coalesce(a.partner, 'direct') as partner
    from claims as c
    left join {{ ref('int_claim_attribution') }} as a using (claim_id)

),

with_terms as (

    select
        a.*,
        coalesce(p.fee_model, 'none') as fee_model,
        p.flat_fee_cents,
        p.fee_rate
    from attributed as a
    left join {{ ref('stg_partners') }} as p on a.partner = p.partner

),

calculated as (

    select
        *,
        case fee_model
            when 'flat'       then flat_fee_cents
            when 'percentage' then cast(round(pbm_fee_cents * fee_rate) as bigint)
            else 0
        end as contracted_partner_fee_cents
    from with_terms

)

select
    claim_id,
    partner,
    fee_model,
    pbm_fee_cents,
    contracted_partner_fee_cents,
    least(contracted_partner_fee_cents, pbm_fee_cents) as partner_fee_cents,
    pbm_fee_cents - least(contracted_partner_fee_cents, pbm_fee_cents)
        as wls_net_fee_cents,
    contracted_partner_fee_cents > pbm_fee_cents as partner_fee_was_capped,
    greatest(contracted_partner_fee_cents - pbm_fee_cents, 0)
        as capped_shortfall_cents
from calculated
