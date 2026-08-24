-- End-to-end reconciliation: every row that entered raw.claims is either in
-- fct_claim or in dq_rejects. No row disappears along the way.
--
-- This is the test that holds up the quarantine policy. If someone adds a filter
-- to an intermediate model and forgets to record the reason, the arithmetic
-- stops balancing here — and not in a meeting three weeks later.

with counted as (

    select
        (select count(*) from {{ source('raw', 'claims') }})                        as landed,
        (select count(*) from {{ ref('fct_claim') }})                               as kept,
        (select count(*) from {{ ref('dq_rejects') }} where source_table = 'claims') as rejected

)

select *
from counted
where landed <> kept + rejected
