-- One row per pharmacy. Full reload each run.
--
-- Reference data moves slowly (a pharmacy rarely changes chain), so there's no
-- SCD-2 here: the warehouse always sees today's reference data. That means if a
-- pharmacy changes chain, its entire history is reattributed to the new one. For
-- the questions in play (partner mix, margin by chain) current state is what
-- matters. The path to SCD-2 is described in the README.

select
    npi as pharmacy_npi,
    chain,
    _source_file
from {{ ref('stg_pharmacies') }}
