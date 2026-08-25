-- **The analysable claim universe.** Claims that survived staging, plus the one
-- rule that needs a second table.
--
-- ## Why this isn't a line in stg_claims
--
-- "Is this NPI one of ours?" can't be answered from the claim event — it needs
-- `stg_pharmacies`. A staging model that reads another model turns the layer from
-- a flat fan-out into a chain: you can no longer rebuild one staging model alone,
-- and its unit tests have to fabricate rows for a table the source knows nothing
-- about.
--
-- The stronger reason is semantic. Two different things shared one column:
--
-- * `"one hundred"` in a price is **malformed**. Somebody upstream fixes it, and
--   the row never comes back on its own.
-- * A claim from NPI `1419925182` is **out of scope** — a well-formed claim, real
--   revenue on it, for a pharmacy we don't have on file. The day that pharmacy is
--   onboarded, all 460 such claims (across 4 unknown NPIs) return by themselves.
--
-- Bucketing those together made "how much of what I rejected is recoverable?"
-- unanswerable. `dq_rejects.defect_class` answers it now.
--
-- ## The scope rule
--
-- The brief is explicit: *"We only care about events for pharmacies that exist in
-- the pharmacy dataset."* So an unknown NPI is excluded, not dropped — same
-- quarantine contract as staging, different column because it means something
-- different.

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
