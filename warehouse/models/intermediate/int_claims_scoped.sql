-- **The analysable claim universe.** Claims that survived staging, with the one
-- rule that needs another table applied on top.
--
-- ## Why this is a model and not a line in stg_claims
--
-- "Is this NPI one of ours?" cannot be answered from the claim event. It needs
-- `stg_pharmacies`, and a staging model that reads another model turns the
-- staging layer from a flat fan-out into a chain: you can no longer rebuild one
-- staging model on its own, and its unit tests have to fabricate rows for a
-- table the source knows nothing about.
--
-- The stronger reason is semantic. Two very different things were sharing one
-- column:
--
-- * `"one hundred"` in a price field is **malformed**. Somebody upstream has to
--   fix it, and the row never comes back on its own.
-- * A claim from NPI `1999999999` is **out of scope**. It is a perfectly well
--   formed claim, with real revenue on it, for a pharmacy we don't have on file.
--   The day that pharmacy is onboarded, all 460 of them return by themselves.
--
-- Bucketing those together made "how much of what I rejected is recoverable?"
-- unanswerable. `dq_rejects.defect_class` answers it now.
--
-- ## The scope rule
--
-- The brief is explicit: *"We only care about events for pharmacies that exist
-- in the pharmacy dataset."* So an unknown NPI is excluded, not dropped — same
-- quarantine contract as staging, different column name because it means a
-- different thing.
--
-- Precedence still holds across the layer boundary, for free: only rows with
-- `dq_reject_reason is null` reach here, so a claim that is both malformed *and*
-- out of scope is still reported as malformed. That is the ordering the CASE in
-- `stg_claims` encodes, and it survives the split without being restated.

with claims as (

    select * from {{ ref('stg_claims') }}
    where dq_reject_reason is null

),

known_pharmacies as (

    select npi from {{ ref('stg_pharmacies') }}

)

select
    -- dq_reject_reason is always NULL by construction here; carrying it forward
    -- would give downstream models two columns to filter on instead of one.
    c.* exclude (dq_reject_reason),

    case
        when p.npi is null then 'unknown_npi'
    end as scope_exclusion_reason

from claims as c
left join known_pharmacies as p using (npi)
