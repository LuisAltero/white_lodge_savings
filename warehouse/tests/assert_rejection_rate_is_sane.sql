-- `assert_no_claim_is_lost_silently` checks that `landed = kept + rejected`. That
-- arithmetic still balances when *every* row is rejected, which is exactly what a
-- schema change looks like from inside the warehouse. Rename `price` to `amount`
-- upstream and `read_json` lands the column as NULL rather than failing — staging
-- quarantines all 42,840 claims as `missing_required_field`, GMV comes out $0,
-- and `dbt build` still reports 122 passing tests and exits 0.
--
-- So this test asserts the other half: a source whose rejection rate suddenly
-- goes through the roof did not get dirtier, it changed shape. Today the rates
-- are 3.4% (claims), 3.6% (reverts) and 0.5% (lookups) — 20% is roughly five
-- times the worst of them, loose enough that normal drift in the data never
-- trips it and tight enough that a broken column contract always does.
--
-- CSV sources need no equivalent: their columns are projected by name, so a
-- rename fails loudly with a binder error at landing time.

with landed as (

    select 'claims'  as source_table, count(*) as landed from {{ source('raw', 'claims') }}
    union all
    select 'reverts', count(*) from {{ source('raw', 'reverts') }}
    union all
    select 'lookups', count(*) from {{ source('raw', 'lookups') }}

),

rejected as (

    select source_table, count(*) as rejected
    from {{ ref('dq_rejects') }}
    group by source_table

)

select
    l.source_table,
    l.landed,
    coalesce(r.rejected, 0) as rejected,
    round(100.0 * coalesce(r.rejected, 0) / l.landed, 2) as rejection_pct
from landed as l
left join rejected as r using (source_table)
where l.landed > 0
  and coalesce(r.rejected, 0) > 0.20 * l.landed
