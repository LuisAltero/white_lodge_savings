-- One claim event per row, typed, with its rejection reason attached.
--
-- Malformed-record policy: **quarantine, don't drop**. No row disappears here.
-- Every one comes out with a `dq_reject_reason` — NULL when it's clean.
-- Downstream models filter on NULL; `dq_rejects` collects the rest with the
-- reason and the original text that arrived.
--
-- That costs one column and buys the ability to answer "how much data are we
-- losing, for which reason, from which file" — which is the question that always
-- comes up when a number looks lower than expected.
--
-- The CASE ordering *is* the policy, and it is deliberate: most structural
-- defect first, most semantic last. A row with a missing field *and* an unknown
-- NPI is reported as `missing_required_field`, because that's the problem the
-- data producer has to fix first.

with source as (

    select * from {{ source('raw', 'claims') }}

),

parsed as (

    select
        nullif(trim(id), '')    as claim_id,
        nullif(trim(npi), '')   as npi,
        nullif(trim(ndc), '')   as ndc,

        try_cast(price as double)          as price,
        try_cast(quantity as double)       as quantity,
        try_cast(pbm_fee as double)        as pbm_fee,
        try_cast("timestamp" as timestamp) as filled_at,

        -- The raw text rides along: without it, `dq_rejects` would say
        -- "unreadable number" without being able to show that the number was
        -- the word "one hundred".
        price       as price_raw,
        quantity    as quantity_raw,
        pbm_fee     as pbm_fee_raw,
        "timestamp" as timestamp_raw,

        _source_file
    from source

),

with_duplicates as (

    select
        *,
        count(*) over (partition by claim_id) as id_occurrences
    from parsed

),

with_pharmacy as (

    select
        c.*,
        p.npi is not null as npi_is_known
    from with_duplicates as c
    left join {{ ref('stg_pharmacies') }} as p using (npi)

)

select
    claim_id,
    npi,
    ndc,
    filled_at,
    cast(filled_at as date) as filled_date,

    {{ to_cents('price') }}   as price_cents,
    {{ to_cents('pbm_fee') }} as pbm_fee_cents,
    quantity,

    price_raw,
    quantity_raw,
    pbm_fee_raw,
    timestamp_raw,
    id_occurrences,
    _source_file,

    case
        -- 1. Required field absent from the file (148 rows in the sample).
        when claim_id is null
             or npi is null
             or ndc is null
             or price_raw is null
             or quantity_raw is null
             or pbm_fee_raw is null
             or timestamp_raw is null
            then 'missing_required_field'

        -- 2. Unreadable number: `"one hundred"`, `"thirty"` (126 rows). We do
        --    not translate spelled-out numbers — that would be an endless rule
        --    set reconstructing a value we'd be guessing at.
        when price is null or quantity is null or pbm_fee is null
            then 'unparseable_number'

        -- 3. Impossible timestamp: `2026-13-45T99:99:99`, `not-a-date` (146).
        when filled_at is null
            then 'unparseable_timestamp'

        -- 4. Economically meaningless value: negative quantity (117) or
        --    zero/negative price (162). A zero price with a positive pbm_fee
        --    doesn't add up: nobody charges a fee on a sale that didn't happen.
        when price <= 0 or quantity <= 0
            then 'non_positive_amount'

        -- 5. Same UUID, different content (140 ids, 281 rows). Verified: *none*
        --    of these duplicates is an identical copy — they are entirely
        --    different claims competing for one id. There is no way to pick a
        --    winner without inventing a criterion, and picking wrong corrupts
        --    revenue silently. Quarantine both sides.
        when id_occurrences > 1
            then 'duplicate_claim_id'

        -- 6. Pharmacy not in the reference data (460 here; 472 in the file, the
        --    other 12 already caught by earlier rules). The brief is explicit:
        --    we only care about events for pharmacies in the dataset.
        when not npi_is_known
            then 'unknown_npi'
    end as dq_reject_reason

from with_pharmacy
