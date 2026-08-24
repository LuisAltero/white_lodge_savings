-- Pharmacy reference data. Slowly changing: fully reloaded on every run.
--
-- This is the table that defines the universe of valid events — the brief says
-- we only care about events for pharmacies that exist here.

with source as (

    select * from {{ source('raw', 'pharmacies') }}

),

cleaned as (

    select
        nullif(trim(npi), '')          as npi,
        lower(nullif(trim(chain), '')) as chain,
        _source_file
    from source

)

select
    npi,
    coalesce(chain, 'unknown') as chain,
    _source_file
from cleaned
where npi is not null
-- Defensive: if two reference files ever arrive carrying the same NPI, the fact
-- table must not double through the join. One row per NPI, always.
qualify row_number() over (partition by npi order by chain) = 1
